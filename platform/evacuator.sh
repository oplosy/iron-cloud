#!/usr/bin/env bash
# Runs on ctl1 as ironcloud-evacuator.service (installed by deploy.sh stage "evacuator").
# Moves department VMs off a compute node that is really down, restarts the ones that were
# running, and re-enables the node once nova-compute reports up again.
#
# "Really down" needs three independent signals for $GRACE checks in a row: Nova marks
# nova-compute down, the node does not answer ping, and Ceph has marked all its OSDs down.
# A node is only evacuated after this service has seen it up once: while the lab starts, a
# node that has not booted yet looks exactly like a dead one.
# Evacuating a VM whose old host still runs would give two writers on one volume; the RBD
# exclusive lock is the second line of defence (a dead lock holder is blocklisted when the
# new host breaks its lock).
set -uo pipefail
INTERVAL=${INTERVAL:-10}
GRACE=${GRACE:-2}
REASON=ironcloud-evacuator
declare -A IP=([cmp1]=10.20.0.12 [cmp2]=10.20.0.13)

# stdin closed: the main loop reads the service list from its stdin.
os() { OS_CLOUD=kolla-admin ~/osc-venv/bin/openstack "$@" </dev/null; }
log() { echo "$*"; } # journald adds the timestamp
pings() { ping -c1 -W1 "$1" >/dev/null 2>&1; }
# all_osds_down <host>: every OSD on the host is in "ceph osd tree down".
all_osds_down() {
    local ids down id
    ids=$(sudo ceph osd ls-tree "$1" 2>/dev/null) && [ -n "$ids" ] || return 1
    down=$(sudo ceph osd tree down 2>/dev/null) || return 1
    for id in $ids; do grep -qw "osd.$id" <<<"$down" || return 1; done
}
# should_evacuate <nova state> <pings 0|1> <osds down 0|1> <other computes up> <seen up 0|1>
should_evacuate() { [ "$1" = down ] && [ "$2" = 0 ] && [ "$3" = 1 ] && [ "$4" -gt 0 ] && [ "$5" = 1 ]; }
# rebuilt_elsewhere <server> <old host>: on another host and settled (no rebuild in progress).
rebuilt_elsewhere() {
    local host status
    host=$(os server show "$1" -f value -c OS-EXT-SRV-ATTR:host) && status=$(os server show "$1" -f value -c status) || return 1
    [ "$host" != "$2" ] && [[ $status =~ ^(SHUTOFF|ACTIVE)$ ]]
}

# evacuate_host <host>: evacuate every VM on it, then start the ones that were running.
evacuate_host() {
    local h=$1 id status rows=() row end
    os compute service set --disable --disable-reason "$REASON" "$h" nova-compute
    mapfile -t rows < <(os server list --all-projects --host "$h" -f value -c ID -c Status)
    [ ${#rows[@]} -gt 0 ] || { log "$h: no VMs to evacuate"; return; }
    for row in "${rows[@]}"; do
        read -r id status <<<"$row"
        log "$h: evacuate $id (was $status)"
        os server evacuate "$id" >/dev/null || log "$h: evacuate $id FAILED"
    done
    for row in "${rows[@]}"; do
        read -r id status <<<"$row"
        end=$(($(date +%s) + 300))
        until rebuilt_elsewhere "$id" "$h"; do
            [ "$(date +%s)" -ge $end ] && { log "$h: $id not rebuilt elsewhere after 300 s"; continue 2; }
            sleep 3
        done
        log "$h: $id rebuilt on $(os server show "$id" -f value -c OS-EXT-SRV-ATTR:host)"
        # Compute API 2.95+ leaves an evacuated server SHUTOFF on its new host.
        if [ "$status" = ACTIVE ] && [ "$(os server show "$id" -f value -c status)" = SHUTOFF ]; then
            os server start "$id" && log "$h: started $id"
        fi
    done
}

declare -A strikes=() seen=() told=()
# tick: one pass over the nova-compute services.
tick() {
    local services up h status state reason p o
    # "<host> <status> <state> <disabled reason>"; empty while the APIs on ctl1 are down.
    services=$(os compute service list --service nova-compute --long -f value -c Host -c Status -c State -c "Disabled Reason" 2>/dev/null) || return 0
    up=$(awk '$3 == "up"' <<<"$services" | wc -l)
    while read -r h status state reason; do
        [ -n "${IP[$h]:-}" ] || continue
        if [ "$state" = up ]; then
            strikes[$h]=0 seen[$h]=1
            if [ "$status" = disabled ] && [ "$reason" = "$REASON" ]; then
                os compute service set --enable "$h" nova-compute && log "$h: back up, re-enabled"
            fi
            continue
        fi
        p=0 o=0
        pings "${IP[$h]}" && p=1
        all_osds_down "$h" && o=1
        if [ -z "${seen[$h]:-}" ] && [ -z "${told[$h]:-}" ] && should_evacuate "$state" $p $o "$up" 1; then
            log "$h: down, but not seen up since this service started; waiting for it to boot"
            told[$h]=1
        fi
        if should_evacuate "$state" $p $o "$up" "${seen[$h]:-0}"; then
            strikes[$h]=$((${strikes[$h]:-0} + 1))
        else
            strikes[$h]=0
        fi
        [ "${strikes[$h]}" -eq "$GRACE" ] || continue
        log "$h: down (nova down, no ping, OSDs down) for $GRACE checks; evacuating"
        evacuate_host "$h"
    done <<<"$services"
}

# Sourced by tests/run.sh: define the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

log "watching ${!IP[*]} every ${INTERVAL}s, acting after $GRACE checks"
while sleep "$INTERVAL"; do tick; done
