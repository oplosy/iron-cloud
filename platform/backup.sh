#!/usr/bin/env bash
# Runs on the Windows host (Git Bash), so backups live off the cluster on the host's disk.
# Backs up department VM boot volumes from Ceph and restores them.
# Usage: platform/backup.sh backup <department>           every VM's boot volume -> $BACKUP_DIR/<department>/
#        platform/backup.sh restore <department> <vm> <file>   replace the VM's boot volume with a backup
#        platform/backup.sh test <department> <vm>         write data, back up, damage it, restore, compare;
#                                                          writes reports/<date>-<vm>-restore-test.md
# A backup is a full export of an RBD snapshot taken while the VM runs: crash-consistent, like
# the power cuts in failure-test.sh. shortcut: full exports only (a 1 GB CirrOS volume is ~20 MB
# gzipped); switch to rbd export-diff chains when volumes grow.
set -euo pipefail
KEY=~/.ssh/ironcloud_ed25519
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BACKUP_DIR=${BACKUP_DIR:-~/ironcloud-backups}

on() { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 ubuntu@10.20.0.11 "$@"; }
osc() { on "OS_CLOUD=kolla-admin ~/osc-venv/bin/openstack $*"; }
# Department VMs accept SSH only from the platform address, so go through ctl1. Stdin is the script.
vm() { on "ssh -q -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes cirros@$1 sh -s"; }
# Functions print their result on stdout; progress goes to stderr.
log() { echo "==> $(date +%T) $*" >&2; }
# server_id <department> <vm>
server_id() {
    local id
    id=$(osc server list --project "$1" --name "^$2\$" -f value -c ID)
    [ "$(wc -w <<<"$id")" = 1 ] || { echo "Expected one VM '$2' in project '$1', found: ${id:-none}" >&2; return 1; }
    echo "$id"
}
boot_volume() { osc server show "$1" -f json -c volumes_attached | python -c 'import json,sys; print(json.load(sys.stdin)["volumes_attached"][0]["id"])'; }
fip_of() { osc server show "$1" -f value -c addresses | grep -o '10\.20\.1\.[0-9]*' | head -1; }
status_of() { osc server show "$1" -f value -c status; }
wait_status() { # <server> <status> <timeout s>
    local end=$(($(date +%s) + $3))
    until [ "$(status_of "$1")" = "$2" ]; do
        [ "$(date +%s)" -lt $end ] || { echo "$1 not $2 after $3 s" >&2; return 1; }
        sleep 3
    done
}

# backup_vm <department> <vm>: prints the backup file path.
backup_vm() {
    local id vol snap out
    id=$(server_id "$1" "$2") && vol=$(boot_volume "$id") || return 1
    snap=ironcloud-$(date -u +%Y%m%dT%H%M%SZ)
    out="$BACKUP_DIR/$1/$2-$snap.raw.gz"
    mkdir -p "$BACKUP_DIR/$1"
    on "sudo rbd snap create --no-progress volumes/volume-$vol@$snap" >&2 || return 1
    # Remove the snapshot even if the export fails: Cinder cannot delete a volume that has one.
    if ! on "set -o pipefail; sudo rbd export --no-progress volumes/volume-$vol@$snap - | gzip -1" > "$out.part"; then
        on "sudo rbd snap rm --no-progress volumes/volume-$vol@$snap" >&2 || true
        rm -f "$out.part"
        echo "Export of $1/$2 (volume $vol) failed" >&2
        return 1
    fi
    on "sudo rbd snap rm --no-progress volumes/volume-$vol@$snap" >&2
    mv "$out.part" "$out"
    (cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
    echo "$out"
}

# restore_vm <department> <vm> <file>: stops the VM, swaps in the backup, starts it again.
# The replaced image is kept as volume-<id>.pre-restore-<time> until the operator removes it.
restore_vm() {
    local id vol file=$3 keep
    [ -f "$file" ] && [ -f "$file.sha256" ] || { echo "Missing $file or its .sha256" >&2; return 1; }
    (cd "$(dirname "$file")" && sha256sum -c --quiet "$(basename "$file").sha256") || { echo "Checksum mismatch: $file" >&2; return 1; }
    id=$(server_id "$1" "$2") && vol=$(boot_volume "$id") || return 1
    keep=volume-$vol.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)
    log "stop $1/$2"
    [ "$(status_of "$id")" = SHUTOFF ] || osc server stop "$id"
    wait_status "$id" SHUTOFF 120 || return 1
    log "keep current image as volumes/$keep, import backup as volumes/volume-$vol"
    # Only after this rename succeeds may anything named volume-$vol be removed.
    on "sudo rbd mv volumes/volume-$vol volumes/$keep" || { echo "Could not set the current image aside; nothing changed" >&2; osc server start "$id"; return 1; }
    if ! gunzip -c "$file" | on "sudo rbd import --no-progress - volumes/volume-$vol"; then
        echo "Import failed; putting the original image back" >&2
        on "sudo rbd rm --no-progress volumes/volume-$vol 2>/dev/null; sudo rbd mv volumes/$keep volumes/volume-$vol"             || echo "ROLLBACK FAILED: the original image is volumes/$keep; rename it to volume-$vol by hand" >&2
        osc server start "$id"
        return 1
    fi
    log "start $1/$2"
    osc server start "$id"
    wait_status "$id" ACTIVE 300
    echo "Restored. After checking the VM, remove the old image: ssh ctl1 sudo rbd rm volumes/$keep" >&2
    echo "$keep"
}

# restore_test <department> <vm>
restore_test() {
    local d=$1 v=$2 id fip sum_before sum_damaged sum_after file keep t0 t_backup t_restore size
    id=$(server_id "$d" "$v") && fip=$(fip_of "$id")
    [ -n "$fip" ] || { echo "No floating IP for $d/$v" >&2; return 1; }
    t0=$(date +%s)
    log "write 4 MB of test data inside $d/$v"
    sum_before=$(echo 'dd if=/dev/urandom of=restore-probe bs=1k count=4096 2>/dev/null; sync; md5sum restore-probe' | vm "$fip" | cut -d' ' -f1)
    [ -n "$sum_before" ] || { echo "Could not write test data in $d/$v" >&2; return 1; }
    log "back up"
    file=$(backup_vm "$d" "$v") || return 1
    t_backup=$(($(date +%s) - t0))
    size=$(du -h "$file" | cut -f1)
    log "damage: overwrite the test data with zeros"
    sum_damaged=$(echo 'dd if=/dev/zero of=restore-probe bs=1k count=4096 2>/dev/null; sync; md5sum restore-probe' | vm "$fip" | cut -d' ' -f1)
    t0=$(date +%s)
    keep=$(restore_vm "$d" "$v" "$file") || return 1
    for _ in $(seq 60); do echo true | vm "$fip" 2>/dev/null && break; sleep 5; done
    t_restore=$(($(date +%s) - t0))
    sum_after=$(echo 'md5sum restore-probe' | vm "$fip" | cut -d' ' -f1)
    local result=FAIL
    [ "$sum_after" = "$sum_before" ] && [ "$sum_damaged" != "$sum_before" ] && result=PASS
    [ $result = PASS ] && on "sudo rbd rm --no-progress volumes/$keep"
    mkdir -p "$ROOT/reports"
    local report
    report="$ROOT/reports/$(date +%Y%m%d-%H%M)-$v-restore-test.md"
    cat > "$report" <<EOF
# Restore test: $d/$v

$(date '+%Y-%m-%d %H:%M'). Result: **$result**.

| Step | Result |
|---|---|
| Test data written inside the VM | md5 $sum_before |
| Backup (RBD snapshot, export, gzip to the host) | $t_backup s, $size, \`$(basename "$file")\` |
| Damage: test data overwritten with zeros | md5 $sum_damaged |
| Restore (stop, swap image, start) until SSH answers | $t_restore s |
| Test data after restore | md5 $sum_after |

The backup is crash-consistent: the snapshot is taken while the VM runs, as if its power had been cut at that moment.
$([ $result = PASS ] && echo "The replaced image was removed after the checksum matched." || echo "The replaced image is kept as \`volumes/$keep\` for inspection.")
EOF
    log "$result: report $report"
    [ $result = PASS ]
}

case "${1:-}" in
    backup)
        [ $# -eq 2 ] || { echo "Usage: $0 backup <department>" >&2; exit 1; }
        mapfile -t vms < <(osc server list --project "$2" -f value -c Name)
        [ ${#vms[@]} -gt 0 ] || { echo "No VMs in project $2" >&2; exit 1; }
        for v in "${vms[@]}"; do log "backup $2/$v"; backup_vm "$2" "$v"; done
        ;;
    restore)
        [ $# -eq 4 ] || { echo "Usage: $0 restore <department> <vm> <file>" >&2; exit 1; }
        restore_vm "$2" "$3" "$4" >/dev/null
        ;;
    test)
        [ $# -eq 3 ] || { echo "Usage: $0 test <department> <vm>" >&2; exit 1; }
        restore_test "$2" "$3"
        ;;
    *) sed -n '3,8p' "$0" >&2; exit 1 ;;
esac
