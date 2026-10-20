#!/usr/bin/env bash
# Unit tests for the pure functions in platform/ scripts. No lab needed; runs in CI and on the host.
# Usage: tests/run.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fails=0 total=0
# check <name> <expected> <actual>
check() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1"; echo "      want: $2"; echo "      got:  $3"; fails=$((fails + 1)); fi
}

# --- failure-test.sh ---
# shellcheck source=platform/failure-test.sh
source "$ROOT/platform/failure-test.sh" cmp1

check "gap: no loss" "ping seq: 5 samples, longest gap 1" "$(gap_report "ping seq" "" "ew 5 1 2 3 4 5")"
check "gap: middle outage" "ping seq: 5 samples, longest gap 40 seconds" "$(gap_report "ping seq" " seconds" "inet 45 1 2 3 43 45")"
check "gap: tail outage counted" \
    "ping seq: 3 samples, longest gap 37 seconds; no samples in the last 37 s before the logs were read (had not resumed by then)" \
    "$(gap_report "ping seq" " seconds" "inet 40 1 2 3")"
check "gap: tail of 2 is jitter" "ping seq: 3 samples, longest gap 1" "$(gap_report "ping seq" "" "ew 5 1 2 3")"
check "gap: missing end does not invent a tail" "ping seq: 3 samples, longest gap 1" "$(gap_report "ping seq" "" "ew 0 1 2 3")"
check "gap: no samples" "io writes: no samples" "$(gap_report "io writes" " seconds" "io 1792502805")"

unset T0
SNAPSHOTS=()
printf 'HEALTH_OK\n' | snapshot "Ceph before"
check "snapshot: kept in this shell (lastpipe)" 5 "${#SNAPSHOTS[@]}"
check "snapshot: no time before the power cut" "### Ceph before" "${SNAPSHOTS[0]}"
T0=$(date +%s)
echo x | snapshot "during"
check "snapshot: time once T0 is set" "### during (t+0s)" "${SNAPSHOTS[5]}"

# --- evacuator.sh ---
# shellcheck source=platform/evacuator.sh
source "$ROOT/platform/evacuator.sh"
decide() { if should_evacuate "$@"; then echo evacuate; else echo wait; fi; }
check "evacuate: all signals agree" evacuate "$(decide down 0 1 1)"
check "evacuate: nova up" wait "$(decide up 0 1 1)"
check "evacuate: node still answers ping" wait "$(decide down 1 1 1)"
check "evacuate: OSDs still up" wait "$(decide down 0 0 1)"
check "evacuate: no other compute up" wait "$(decide down 0 1 0)"

# --- gitops.sh ---
# shellcheck source=platform/gitops.sh
source "$ROOT/platform/gitops.sh"
plan_out='==> plan: engineering
No changes. Your infrastructure matches the configuration.
==> plan: finance
Plan: 0 to add, 1 to change, 0 to destroy.'
check "gitops: plan summary" "engineering: no changes; finance: +0 ~1 -0" "$(short <<<"$plan_out")"
apply_out='==> apply: finance
Apply complete! Resources: 2 added, 0 changed, 1 destroyed.
==> apply: research
╷
│ Error: Resource precondition failed
│ 
│   on main.tf line 69, in resource "openstack_identity_project_v3" "dept":
│ 
│ Requested VMs need
│ {"instances":1}, which
│ does not fit the department quota.
╵
╷
│ Error: Another one
╵'
check "gitops: apply summary, one error per department" "finance: +2 ~0 -1; research: error" "$(short <<<"$apply_out")"
check "gitops: error message in the summary"     'Error: Resource precondition failed: Requested VMs need {"instances":1}, which does not fit the department quota.'     "$(summary <<<"$apply_out" | sed -n 4p)"
check "gitops: colours stripped" "Plan: 1 to add" "$(printf '[1mPlan:[0m 1 to add' | strip_ansi)"

echo "$((total - fails))/$total passed"
[ "$fails" -eq 0 ]
