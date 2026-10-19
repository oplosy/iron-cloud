#!/usr/bin/env bash
# Runs on the Windows host (Git Bash): it must keep observing while ctl1 is down and power nodes
# back on through Hyper-V. Cuts power to one node, records what broke and how it recovered,
# checks data integrity and writes a Markdown report to reports/.
# Usage: platform/failure-test.sh cmp1|cmp2|ctl1
set -uo pipefail
NODE=${1:-}
[[ $NODE =~ ^(cmp1|cmp2|ctl1)$ ]] || { echo "Usage: $0 cmp1|cmp2|ctl1" >&2; exit 1; }
KEY=~/.ssh/ironcloud_ed25519
ROOT=$(cd "$(dirname "$0")/.." && pwd)
declare -A IP=([ctl1]=10.20.0.11 [cmp1]=10.20.0.12 [cmp2]=10.20.0.13)
API=http://10.20.0.11:5000/v3
PROMETHEUS=http://10.20.0.13:9091

on() { local n=$1; shift; ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "ubuntu@${IP[$n]}" "$@"; }
osc() { on ctl1 "OS_CLOUD=kolla-admin ~/osc-venv/bin/openstack $*"; }
# Department VMs accept SSH only from the platform address, so go through ctl1. Stdin is the script.
vm() { [ -n "$1" ] || { echo "vm: empty address" >&2; return 1; }; on ctl1 "ssh -q -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes cirros@$1 sh -s"; }
host_ping() { ping -n 1 -w 1000 "$1" | grep -q "TTL="; }
fip_of() { osc server show "$1" -f value -c addresses | grep -o '10\.20\.1\.[0-9]*' | head -1; }
fixed_of() { osc server show "$1" -f value -c addresses | grep -o '192\.168\.[0-9]*\.[0-9]*' | head -1; }

EVENTS=() SNAPSHOTS=() FINDINGS=()
now() { echo $(($(date +%s) - T0)); }
event() { EVENTS+=("| $(now) | $* |"); echo "  t+$(now)s  $*"; }
finding() { FINDINGS+=("- $*"); echo "  >> $*"; }
snapshot() { SNAPSHOTS+=("### $1 (t+$(now)s)" '```' "$(cat)" '```' ''); }
# wait_for <label> <timeout s> <command...>: records the time the command first succeeds.
wait_for() {
    local label=$1 end=$(($(date +%s) + $2))
    shift 2
    until "$@" >/dev/null 2>&1; do
        [ "$(date +%s)" -ge $end ] && { event "TIMEOUT after $(now)s: $label"; return 1; }
        sleep 2
    done
    event "$label"
}
not() { ! "$@"; }

cut_power() {
    T0=$(date +%s)
    # Immediate power-off from inside the kernel: no sync, no service shutdown, like pulling the plug.
    on "$1" "sudo sh -c 'echo o > /proc/sysrq-trigger'" >/dev/null 2>&1 &
    event "power cut to $1 (sysrq poweroff)"
}

power_on() {
    event "power restored to $1"
    powershell.exe -NoProfile -Command "Start-VM -Name $1 -ErrorAction Stop" >/dev/null 2>&1 && return
    echo "  (approve the UAC prompt: Hyper-V needs elevation to start $1)"
    powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-Command','Start-VM -Name $1'"
}

# Admin CLI for Ceph from whichever node is still alive.
ceph_on() { local n=$1; shift; on "$n" "sudo ceph $*"; }
osd_of() { ceph_on "$1" osd ls-tree "$2" | head -1; }
osd_down() { ceph_on "$1" osd tree down | grep -qw "osd.$2"; }
ceph_ok() { ceph_on "$1" health | grep -q HEALTH_OK; }
# rados_probe <ceph node> <object>: writes 4 MB of random data to the volumes pool, prints its md5.
rados_probe() {
    on "$1" "head -c 4M /dev/urandom > /tmp/$2 && sudo timeout 60 rados -p volumes put $2 /tmp/$2 && md5sum < /tmp/$2" | cut -d' ' -f1
}
rados_md5() { on "$1" "sudo timeout 60 rados -p volumes get $2 - | md5sum" | cut -d' ' -f1; }
nova_state() { osc compute service list --service nova-compute --host "$1" -f value -c State; }
all_up() { local out; out=$(osc compute service list -f value -c State) && [ -n "$out" ] && ! grep -qv '^up$' <<<"$out"; }
nova_is() { [ "$(nova_state "$1")" = "$2" ]; }
vm_state_on() { [ "$(osc server show "$1" -f value -c status)" = "$2" ] && [ "$(osc server show "$1" -f value -c OS-EXT-SRV-ATTR:host)" = "$3" ]; }
vm_ssh() { echo true | vm "$1"; }
agents_alive() { local out; out=$(osc network agent list -f value -c Alive) && [ -n "$out" ] && ! grep -qv True <<<"$out"; }

scenario_compute() {
    local other ceph=ctl1 vm_id vm_name fip osd sum_before sum_after
    other=$([ "$NODE" = cmp1 ] && echo cmp2 || echo cmp1)
    read -r vm_id vm_name < <(osc server list --all-projects --host "$NODE" -f value -c ID -c Name | head -1)
    [ -n "${vm_id:-}" ] || { echo "No department VM runs on $NODE; nothing to evacuate." >&2; exit 1; }
    fip=$(fip_of "$vm_id")
    osd=$(osd_of $ceph "$NODE")
    echo "VM under test: $vm_name ($vm_id) on $NODE, floating $fip; osd.$osd on $NODE"

    sum_before=$(echo 'dd if=/dev/urandom of=probe bs=1k count=4096 2>/dev/null; sync; md5sum probe' | vm "$fip" | cut -d' ' -f1)
    local obj_before obj_degraded
    obj_before=$(rados_probe $ceph probe-before)
    ceph_on $ceph -s | snapshot "Ceph before"

    cut_power "$NODE"
    wait_for "$NODE stops answering ping" 60 not host_ping "${IP[$NODE]}"
    wait_for "Ceph marks osd.$osd down" 180 osd_down $ceph "$osd"
    ceph_on $ceph -s | snapshot "Ceph while $NODE is down"
    obj_degraded=$(rados_probe $ceph probe-degraded)
    if [ -n "$obj_degraded" ]; then event "4 MB write to pool 'volumes' succeeded while degraded"; else event "write while degraded FAILED"; fi
    wait_for "Nova marks nova-compute on $NODE down" 300 nova_is "$NODE" down

    event "evacuate $vm_name requested"
    osc server evacuate "$vm_id" >/dev/null
    # Compute API >= 2.95 leaves an evacuated server stopped so an operator can check it first.
    wait_for "$vm_name rebuilt on $other from its Ceph volume, left SHUTOFF (API >= 2.95)" 300 vm_state_on "$vm_id" SHUTOFF "$other"
    osc server start "$vm_id"
    event "start $vm_name requested"
    wait_for "$vm_name ACTIVE on $other" 300 vm_state_on "$vm_id" ACTIVE "$other"
    wait_for "$vm_name answers ping on $fip" 300 on ctl1 ping -c1 -W1 "$fip"
    wait_for "$vm_name accepts SSH" 300 vm_ssh "$fip"
    sum_after=$(echo 'md5sum probe' | vm "$fip" | cut -d' ' -f1)
    if [ -n "$sum_before" ] && [ "$sum_before" = "$sum_after" ]; then
        finding "Data written inside $vm_name before the failure is intact after evacuation (md5 $sum_after)."
    else
        finding "DATA MISMATCH in $vm_name: before '$sum_before', after '$sum_after'."
    fi

    power_on "$NODE"
    wait_for "$NODE back on the network" 300 host_ping "${IP[$NODE]}"
    wait_for "osd.$osd back up" 300 not osd_down $ceph "$osd"
    wait_for "nova-compute on $NODE up" 300 nova_is "$NODE" up
    wait_for "Ceph HEALTH_OK, all PGs active+clean" 900 ceph_ok $ceph
    ceph_on $ceph -s | snapshot "Ceph after recovery"

    local a b
    a=$(rados_md5 $ceph probe-before) b=$(rados_md5 $ceph probe-degraded)
    [ "$a" = "$obj_before" ] && [ "$b" = "$obj_degraded" ] && finding "RADOS objects written before and during the failure read back with matching md5 after recovery." \
        || finding "RADOS MISMATCH: probe-before $obj_before/$a, probe-degraded $obj_degraded/$b."
    on $ceph "sudo rados -p volumes rm probe-before; sudo rados -p volumes rm probe-degraded; rm -f /tmp/probe-*" >/dev/null 2>&1
    finding "$vm_name was down from the power cut until it answered ping again on $other (see timeline); Nova does not evacuate on its own."
}

scenario_controller() {
    local a_id a_name b_id b_name a_fip b_fixed ceph=cmp1
    # IDs, not names: "server show <name>" as admin only searches the admin project.
    { read -r a_id a_name; read -r b_id b_name; } < <(osc server list --project engineering -f value -c ID -c Name)
    [ -n "${b_id:-}" ] || { echo "Need two VMs in project engineering." >&2; exit 1; }
    a_fip=$(fip_of "$a_id") b_fixed=$(fixed_of "$b_id")
    [ -n "$a_fip" ] && [ -n "$b_fixed" ] || { echo "Could not read addresses of $a_name/$b_name." >&2; exit 1; }
    echo "Probes run inside engineering/$a_name ($a_fip): ping $b_name ($b_fixed), ping 1.1.1.1, disk writes"

    # Probes inside the VM keep running while ctl1 is down; their logs are read afterwards.
    vm "$a_fip" <<EOF
killall ping 2>/dev/null; rm -f ew.log inet.log io.log
nohup ping $b_fixed > ew.log 2>&1 < /dev/null &
nohup ping 1.1.1.1 > inet.log 2>&1 < /dev/null &
nohup sh -c 'while true; do date +%s >> io.log; sync; sleep 1; done' > /dev/null 2>&1 < /dev/null &
echo \$! > io.pid
EOF
    sleep 5
    echo 'test -s inet.log && test -s io.log' | vm "$a_fip" || { echo "Probes did not start inside $a_name; not cutting power." >&2; exit 1; }
    ceph_on $ceph -s | snapshot "Ceph before"

    cut_power ctl1
    wait_for "ctl1 stops answering ping" 60 not host_ping "${IP[ctl1]}"
    wait_for "Keystone API stops answering" 60 not curl -sf -m 3 "$API"
    sleep 30
    local running=0 n
    for n in cmp1 cmp2; do running=$((running + $(on $n "sudo docker exec nova_libvirt virsh list --name" | grep -c .))); done
    event "$running VMs still running on cmp1+cmp2 (libvirt)"
    ceph_on $ceph -s | snapshot "Ceph while ctl1 is down (seen from cmp1)"
    [ -n "$(rados_probe $ceph probe-ctl1-down)" ] && event "4 MB write to pool 'volumes' succeeded with ctl1 down" || event "write with ctl1 down FAILED"
    # 401 is fine: Kolla protects Prometheus with basic auth; any HTTP answer means it is serving.
    curl -s -m 3 -o /dev/null -w '%{http_code}' "$PROMETHEUS/-/ready" | grep -qE '^(200|401)$' \
        && event "Prometheus on cmp2 still up" || event "Prometheus on cmp2 NOT reachable"
    while [ "$(now)" -lt 120 ]; do sleep 5; done

    power_on ctl1
    wait_for "ctl1 back on the network" 300 host_ping "${IP[ctl1]}"
    wait_for "Keystone API answers" 900 curl -sf -m 3 "$API"
    wait_for "all Nova services up" 900 all_up
    wait_for "all Neutron agents alive" 900 agents_alive
    wait_for "Ceph HEALTH_OK" 900 ceph_ok $ceph
    wait_for "engineering/$a_name reachable again from the platform" 300 on ctl1 ping -c1 -W1 "$a_fip"
    ceph_on $ceph -s | snapshot "Ceph after recovery"
    on $ceph "sudo rados -p volumes rm probe-ctl1-down; rm -f /tmp/probe-*" >/dev/null 2>&1

    # Read the in-VM logs: ping prints one line per reply with seq=N; io.log has one epoch per second.
    local logs
    logs=$(vm "$a_fip" <<'EOF'
killall ping; kill $(cat io.pid) 2>/dev/null
for f in ew inet; do echo "$f $(grep -o 'seq=[0-9]*' $f.log | cut -d= -f2 | tr '\n' ' ')"; done
echo "io $(tr '\n' ' ' < io.log)"
EOF
)
    [ -n "$logs" ] || finding "PROBE LOGS COULD NOT BE READ from $a_name; the in-VM measurements below are empty."
    gap_report() { # <label> <tag numbers...>: sample count and longest gap between consecutive values
        awk -v label="$1" '{ if (NF < 3) { print label ": no samples"; exit }; max = 0; for (i = 3; i <= NF; i++) { d = $i - $(i-1); if (d > max) max = d }; print label ": " NF-1 " samples, longest gap " max }' <<<"$2"
    }
    finding "East-west ($a_name -> $b_name, same network): $(gap_report "ping seq" "$(grep '^ew ' <<<"$logs")") (a gap of 1 means no loss)."
    finding "Routed traffic ($a_name -> 1.1.1.1 via the router on ctl1): $(gap_report "ping seq" "$(grep '^inet ' <<<"$logs")") seconds."
    finding "Disk writes inside $a_name (Ceph-backed volume): $(gap_report "io writes" "$(grep '^io ' <<<"$logs")") seconds."
}

echo "Failure test: $NODE"
STARTED=$(date '+%Y-%m-%d %H:%M')
if [ "$NODE" = ctl1 ]; then scenario_controller; else scenario_compute; fi

mkdir -p "$ROOT/reports"
REPORT="$ROOT/reports/$(date +%Y%m%d-%H%M)-$NODE-failure.md"
{
    echo "# Failure test: $NODE"
    echo
    echo "Started $STARTED. Power cut with \`echo o > /proc/sysrq-trigger\` (no sync, no clean shutdown); power restored with Hyper-V \`Start-VM\`."
    echo
    echo "## Findings"
    echo
    printf '%s\n' "${FINDINGS[@]}"
    echo
    echo "## Timeline"
    echo
    echo "| t+ (s) | Event |"
    echo "|---|---|"
    printf '%s\n' "${EVENTS[@]}"
    echo
    echo "## Snapshots"
    echo
    printf '%s\n' "${SNAPSHOTS[@]}"
} > "$REPORT"
echo "Report: $REPORT"
