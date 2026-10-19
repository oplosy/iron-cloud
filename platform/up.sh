#!/usr/bin/env bash
# Runs on the Windows host (Git Bash). Copies platform/ and departments/ to ctl1:~/ironcloud
# and runs a script there.
# Usage: platform/up.sh [stage...]          runs deploy.sh (stages: see deploy.sh)
#        platform/up.sh <script>.sh [args]  runs another script from platform/
set -euo pipefail
KEY=~/.ssh/ironcloud_ed25519
CTL=ubuntu@10.20.0.11
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ServerAliveInterval=30)
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# ctl1 is the Ansible/cephadm/OpenTofu host; it reuses the lab key to reach every node.
"${SSH[@]}" "$CTL" 'umask 077; mkdir -p ~/.ssh && cat > ~/.ssh/id_ed25519 && printf "Host ctl1 cmp1 cmp2\n  StrictHostKeyChecking accept-new\n" > ~/.ssh/config' < "$KEY"
tar -C "$ROOT" --exclude=platform/up.sh -cf - platform departments | "${SSH[@]}" "$CTL" 'rm -rf ~/ironcloud ~/platform && mkdir ~/ironcloud && tar -C ~/ironcloud -xf -'
script=deploy.sh
case "${1:-}" in *.sh) script=$1; shift ;; esac
"${SSH[@]}" "$CTL" "bash ~/ironcloud/platform/$script $*"
