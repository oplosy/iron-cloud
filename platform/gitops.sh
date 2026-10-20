#!/usr/bin/env bash
# Runs on the Windows host (Git Bash), where the GitHub CLI is logged in. Pull-based GitOps for
# departments: GitHub never reaches the lab; this agent pulls from GitHub and reports back.
#   open PR changing departments/ -> plan, posted as a PR comment and a "lab/plan" commit status
#   new commit on main            -> apply, reported as a "lab/apply" status and on the merged PR
# A PR is planned with main's platform/ code and only the PR's departments/ (YAML is read as
# data), so a PR cannot run its own code on the lab with platform admin credentials.
# Usage: platform/gitops.sh [once|watch [interval s]]
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY=~/.ssh/ironcloud_ed25519
cd "$ROOT" || exit 1

log() { echo "==> $(date +%T) $*"; }
lab_up() { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 ubuntu@10.20.0.11 true 2>/dev/null; }
# status <sha> <context> <state> <description>
status() { gh api "repos/{owner}/{repo}/statuses/$1" -f state="$3" -f context="$2" -f description="${4:0:140}" >/dev/null; }
has_status() { [ -n "$(gh api "repos/{owner}/{repo}/commits/$1/statuses" --jq ".[] | select(.context == \"$2\") | .state")" ]; }
# strip_ansi: tofu prints colours; GitHub comments show them as junk.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
# summary: one line per department plus the verdict lines.
summary() { grep -E '^==>|^Plan:|^Apply complete|No changes\.|^Error:' || true; }
# short: "engineering: no changes; finance: +0 ~1 -0" for the 140-character status description.
short() {
    awk '/^==> /                { d = $NF }
         /No changes\./         { r = r sep d ": no changes"; sep = "; " }
         /^Plan:/               { r = r sep d ": +" $2 " ~" $5 " -" $8; sep = "; " }
         /^Apply complete/      { r = r sep d ": +" $4 " ~" $6 " -" $8; sep = "; " }
         /^Error:/ && !e[d]++   { r = r sep d ": error"; sep = "; " }
         END                    { print r }'
}

# run_departments <mode> <platform ref> <departments ref>: runs departments.sh on the lab from a
# tree assembled from the two refs. Prints the output; exit code is departments.sh's.
run_departments() {
    local tree rc
    tree=$(mktemp -d)
    git archive "$2" platform | tar -x -C "$tree"
    mkdir -p "$tree/departments"
    git archive "$3" departments 2>/dev/null | tar -x -C "$tree" || true
    bash "$tree/platform/up.sh" departments.sh "$1" 2>&1 | strip_ansi
    rc=${PIPESTATUS[0]}
    rm -rf "$tree"
    return "$rc"
}

# comment_body <title> <result> <output> <marker>
comment_body() {
    local out=$3
    # GitHub's comment limit is 65536 characters.
    [ ${#out} -le 60000 ] || out="(first 60000 characters)
${out:0:60000}"
    printf '### %s\n\nResult: **%s**\n\n```\n%s\n```\n\n<details><summary>Full output</summary>\n\n```\n%s\n```\n</details>\n\n<!-- %s -->\n' \
        "$1" "$2" "$(summary <<<"$3")" "$out" "$4"
}

plan_prs() {
    local main=$1 n sha out rc result
    while read -r n sha; do
        [ -n "$n" ] || continue
        gh pr view "$n" --json comments --jq '.comments[].body' | grep -qF "<!-- ironcloud-plan $sha -->" && continue
        log "PR #$n: plan ${sha:0:7}"
        status "$sha" lab/plan pending "Planning on the lab"
        out=$(run_departments plan "$main" "$sha"); rc=$?
        if [ $rc -eq 0 ]; then result=success; else result=failure; fi
        gh pr comment "$n" --body "$(comment_body "Lab plan for ${sha:0:7}" "$result" "$out" "ironcloud-plan $sha")
Planned with platform code from main (${main:0:7}) and this PR's \`departments/\`." >/dev/null
        status "$sha" lab/plan "$result" "$(short <<<"$out")"
        log "PR #$n: $result"
    done < <(gh pr list --state open --json number,headRefOid,files,isCrossRepository \
        --jq '.[] | select(.isCrossRepository | not) | select(any(.files[]; .path | startswith("departments/"))) | "\(.number) \(.headRefOid)"')
}

apply_main() {
    local main=$1 out rc result pr
    has_status "$main" lab/apply && return 0
    log "main: apply ${main:0:7}"
    status "$main" lab/apply pending "Applying on the lab"
    out=$(run_departments apply "$main" "$main"); rc=$?
    if [ $rc -eq 0 ]; then result=success; else result=failure; fi
    status "$main" lab/apply "$result" "$(short <<<"$out")"
    pr=$(gh api "repos/{owner}/{repo}/commits/$main/pulls" --jq '.[0].number // empty')
    [ -z "$pr" ] || gh pr comment "$pr" --body "$(comment_body "Applied ${main:0:7} to the lab" "$result" "$out" "ironcloud-apply $main")" >/dev/null
    log "main: $result"
}

once() {
    lab_up || { log "lab not reachable; skipping"; return 0; }
    git fetch -q origin || { log "git fetch failed"; return 1; }
    local main
    main=$(git rev-parse origin/main)
    plan_prs "$main"
    apply_main "$main"
}

# Sourced by tests/run.sh: define the functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-once}" in
    once) once ;;
    watch) while true; do once; sleep "${2:-60}"; done ;;
    *) sed -n '3,8p' "$0" >&2; exit 1 ;;
esac
