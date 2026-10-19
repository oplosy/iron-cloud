#!/usr/bin/env bash
# Runs on ctl1. Network isolation matrix: from inside every department VM, probe the other VMs,
# the shared services and the internet, and compare each result with the expected one.
# Exit code 1 if any probe differs from the expectation.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SHARED=10.20.1.10
SSH=(ssh -q -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)

mapfile -t VMS < <(bash "$HERE/departments.sh" inventory | grep -v '^==>')
[ ${#VMS[@]} -ge 2 ] || { echo "Need at least 2 department VMs, found ${#VMS[@]}" >&2; exit 1; }

fail=0
# check <source> <target> <probe> <expected open|blocked> <command...>
check() {
    local src=$1 dst=$2 probe=$3 want=$4 got
    shift 4
    if "$@" >/dev/null 2>&1; then got=open; else got=blocked; fi
    local r=PASS
    [ "$got" = "$want" ] || { r=FAIL; fail=1; }
    printf '%-4s  %-20s -> %-34s %-6s want %-7s got %s\n' "$r" "$src" "$dst" "$probe" "$want" "$got"
}
in_vm() { local fip=$1; shift; "${SSH[@]}" "cirros@$fip" "$@"; }
ping_from() { in_vm "$1" ping -c1 -W2 "$2"; }
ssh_port_from() { in_vm "$1" "nc -w 3 $2 22 </dev/null | grep -q SSH-"; }
resolves_from() { in_vm "$1" "nslookup $2 $SHARED | grep -q '$3'"; }

# CirrOS boots in under a minute; wait until every VM accepts SSH from the platform address.
for row in "${VMS[@]}"; do
    read -r _ name _ fip _ <<<"$row"
    for _ in $(seq 30); do in_vm "$fip" true 2>/dev/null && break; sleep 5; done
done

echo "RESULT source                  target                             probe  expected       actual"
for row in "${VMS[@]}"; do
    read -r sd sn _ sfip _ <<<"$row"
    src="$sd/$sn"

    check "platform" "$src floating $sfip" ping open ping -c1 -W2 "$sfip"
    check "platform" "$src floating $sfip" ssh open in_vm "$sfip" true

    for trow in "${VMS[@]}"; do
        read -r td tn tfixed tfip tfqdn <<<"$trow"
        [ "$td/$tn" = "$src" ] && continue
        dst="$td/$tn"
        if [ "$td" = "$sd" ]; then
            check "$src" "$dst private $tfixed" ping open ping_from "$sfip" "$tfixed"
            check "$src" "$dst private $tfixed" ssh open ssh_port_from "$sfip" "$tfixed"
        else
            check "$src" "$dst private $tfixed" ping blocked ping_from "$sfip" "$tfixed"
            check "$src" "$dst floating $tfip" ping blocked ping_from "$sfip" "$tfip"
            check "$src" "$dst floating $tfip" ssh blocked ssh_port_from "$sfip" "$tfip"
        fi
        check "$src" "dns $tfqdn" dns open resolves_from "$sfip" "$tfqdn" "$tfixed"
    done

    check "$src" "dns cloud-images.ubuntu.com" dns open resolves_from "$sfip" cloud-images.ubuntu.com "^Name:"
    check "$src" "internet 1.1.1.1" ping open ping_from "$sfip" 1.1.1.1
    check "$src" "shared services $SHARED" ping open ping_from "$sfip" "$SHARED"
    check "$src" "shared services $SHARED" ssh blocked ssh_port_from "$sfip" "$SHARED"
done

[ $fail = 0 ] && echo "All isolation checks passed." || echo "Isolation checks FAILED."
exit $fail
