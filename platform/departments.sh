#!/usr/bin/env bash
# Runs on ctl1. Applies every departments/<name>.yaml as its own OpenTofu workspace and tears
# down departments whose YAML was removed.
# Usage: departments.sh [plan|inventory]   (default: apply)
#   inventory prints "department vm fixed_ip floating_ip fqdn" for every VM
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEPTS=$(cd "$HERE/../departments" && pwd)
TOFU_VERSION=1.13.1
# Outside ~/ironcloud, which up.sh replaces on every run: state, providers, admin passwords.
STATE=~/ironcloud-state
export TF_DATA_DIR=$STATE/.terraform
# Credentials for the department-scoped provider (see tofu/versions.tf).
TF_VAR_os_auth=$(python3 -c 'import json,os,yaml; a=yaml.safe_load(open(os.path.expanduser("~/.config/openstack/clouds.yaml")))["clouds"]["kolla-admin"]["auth"]; print(json.dumps({k: a[k] for k in ("auth_url","username","password","user_domain_name","project_domain_name")}))')
export TF_VAR_os_auth
mode=${1:-apply}
[[ $mode == apply || $mode == plan || $mode == inventory ]] || { echo "Usage: $0 [plan|inventory]" >&2; exit 1; }
log() { echo "==> $*"; }
tofu() { command tofu -chdir="$HERE/tofu" "$@"; }
# Not exported: the department provider would pick OS_CLOUD up and log into the admin project.
os() { OS_CLOUD=kolla-admin ~/osc-venv/bin/openstack "$@"; }

if [ "$(command tofu version 2>/dev/null | head -1)" != "OpenTofu v$TOFU_VERSION" ]; then
    log "installing OpenTofu $TOFU_VERSION"
    tmp=$(mktemp -d)
    base=https://github.com/opentofu/opentofu/releases/download/v$TOFU_VERSION
    zip=tofu_${TOFU_VERSION}_linux_amd64.zip
    curl -fsSL -o "$tmp/$zip" "$base/$zip"
    curl -fsSL "$base/tofu_${TOFU_VERSION}_SHA256SUMS" | grep " $zip$" | (cd "$tmp" && sha256sum -c -)
    command -v unzip >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq unzip >/dev/null
    unzip -oq "$tmp/$zip" tofu -d "$tmp"
    sudo install -m 755 "$tmp/tofu" /usr/local/bin/tofu
    rm -rf "$tmp"
fi

# Platform key for SSH into department VMs (tests, operations). Keypairs belong to the
# platform user, which is the one booting every department VM.
os keypair show ironcloud-ops >/dev/null 2>&1 || os keypair create --public-key <(ssh-keygen -y -f ~/.ssh/id_ed25519) ironcloud-ops >/dev/null

mkdir -p "$STATE"
tofu init -input=false -backend-config="workspace_dir=$STATE/workspaces" >/dev/null

if [ "$mode" = inventory ]; then
    for d in $(tofu workspace list | tr -d '* ' | grep -vx default | grep -vx '' || true); do
        tofu workspace select "$d" >/dev/null
        tofu output -json vms | python3 -c 'import json,sys; [print(sys.argv[1], n, v["fixed"], v["floating"], v["fqdn"]) for n, v in json.load(sys.stdin).items()]' "$d"
    done
    exit 0
fi
args=(-input=false -var "departments_dir=$DEPTS")
[ "$mode" = apply ] && args+=(-auto-approve)

wanted=$(find "$DEPTS" -maxdepth 1 -name '*.yaml' -printf '%f\n' | sed 's/\.yaml$//' | sort)
for d in $wanted; do
    log "$mode: $d"
    tofu workspace select -or-create "$d" >/dev/null
    tofu "$mode" "${args[@]}" -var "department=$d"
done

for d in $(tofu workspace list | tr -d '* ' | grep -vx default | grep -vx '' || true); do
    grep -qx "$d" <<<"$wanted" && continue
    tofu workspace select "$d" >/dev/null
    if [ "$mode" = plan ]; then
        log "plan: $d (YAML removed, will be destroyed)"
        tofu plan -destroy "${args[@]}" -var "department=$d"
        continue
    fi
    log "destroy: $d (YAML removed)"
    pid=$(tofu output -raw project_id 2>/dev/null || true)
    tofu destroy "${args[@]}" -var "department=$d"
    # Neutron creates a "default" security group in every project; nothing else owns it.
    [ -z "$pid" ] || os security group list -f value -c ID -c Project | awk -v p="$pid" '$2 == p {print $1}' | xargs -r -n1 env OS_CLOUD=kolla-admin ~/osc-venv/bin/openstack security group delete
    tofu workspace select default >/dev/null
    tofu workspace delete "$d" >/dev/null
done
