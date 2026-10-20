#!/usr/bin/env bash
# Runs on ctl1. Deploys Ceph (cephadm) and OpenStack (Kolla-Ansible) on the 3 lab nodes.
# Usage: deploy.sh [stage...]   stages: deps prep shared bootstrap ceph openstack (default: all, in order)
# Every stage is safe to re-run.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KOLLA_VERSION=22.2.0 # OpenStack 2026.1 Gazpacho
VENV=~/kolla-venv
OSC_VENV=~/osc-venv
INV=/etc/kolla/multinode
NODES=(ctl1 cmp1 cmp2)
MON_IP=10.20.0.11
# Pinned to the client version in Ubuntu Cloud Archive and Kolla images: 20.2.4+ issues
# a newer key type that 20.2.0 clients reject ("Malformed input").
CEPH_IMAGE=quay.io/ceph/ceph:v20.2.0
export PATH="$VENV/bin:$PATH" # kolla-ansible looks up ansible-playbook on PATH
log() { echo "==> $(date +%T) $*"; }
# ssh (prep and ceph stages) can leave the shared stdio non-blocking, and ansible-core refuses
# to run like that ("Ansible requires blocking IO"). O_NONBLOCK is shared, so reset it first.
kolla() { python3 -c 'import os; [os.set_blocking(fd, True) for fd in (0, 1, 2)]'; kolla-ansible "$@"; }

stage_deps() {
    log "deps: packages, kolla-ansible $KOLLA_VERSION, openstack client"
    sudo apt-get update -q
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq git python3-dev python3-venv libffi-dev gcc libssl-dev libdbus-glib-1-dev
    # cephadm recommends Ubuntu's docker.io, which breaks the docker-ce that Kolla installs.
    # Ceph from the 2026.1 Cloud Archive (20.2 Tentacle), the same version Kolla's images use as client.
    # Ubuntu's own 19.2.3 CLI cannot read keys made by newer images.
    sudo add-apt-repository -y cloud-archive:gazpacho
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends cephadm ceph-common
    [ -d "$VENV" ] || python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q -U pip
    "$VENV/bin/pip" install -q "kolla-ansible==$KOLLA_VERSION"
    # Separate venv: the client follows OpenStack upper-constraints, kolla-ansible does not.
    [ -d "$OSC_VENV" ] || python3 -m venv "$OSC_VENV"
    "$OSC_VENV/bin/pip" install -q python-openstackclient python-designateclient -c https://releases.openstack.org/constraints/upper/2026.1
    sudo mkdir -p /etc/kolla && sudo chown "$USER:" /etc/kolla
    if [ ! -f /etc/kolla/passwords.yml ]; then
        cp "$VENV/share/kolla-ansible/etc_examples/kolla/passwords.yml" /etc/kolla/
        kolla-genpwd
    fi
    config
    kolla install-deps
}

# Copies repo config to /etc/kolla; runs before every stage that uses it.
config() {
    cp "$HERE/kolla/globals.yml" /etc/kolla/globals.yml
    mkdir -p /etc/kolla/config/grafana/dashboards
    cp "$HERE"/grafana/*.json /etc/kolla/config/grafana/dashboards/
    cat "$HERE/kolla/hosts.ini" > "$INV"
    sed -n '/^\[baremetal:children\]/,$p' "$VENV/share/kolla-ansible/ansible/inventory/multinode" >> "$INV"
    grep -q '^\[baremetal:children\]' "$INV" || { echo "Kolla multinode inventory layout changed" >&2; exit 1; }
    # Prometheus scrapes the OpenStack exporter at the VIP (ctl1), so it must run there, not on cmp2.
    sed -i '/^\[prometheus-openstack-exporter:children\]/{n;s/^monitoring$/control/}' "$INV"
    grep -A1 '^\[prometheus-openstack-exporter:children\]' "$INV" | grep -qx control || { echo "openstack-exporter group not moved" >&2; exit 1; }
}

stage_prep() {
    log "prep: 2 GB swap and lvm2 on every node"
    for n in "${NODES[@]}"; do
        ssh "$n" 'sudo bash -s' <<'EOF'
set -e
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
    [ -f /swapfile ] || { fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
    swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
DEBIAN_FRONTEND=noninteractive apt-get install -yq lvm2 >/dev/null
EOF
    done
}

# Shared-services address on the provider network (ctl1 only). Departments reach it through
# their routers; nftables lets them use DNS and ping, nothing else on ctl1.
stage_shared() {
    log "shared: 10.20.1.10 on svc0, firewalled to DNS and ICMP"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq nftables >/dev/null
    sudo tee /etc/netplan/60-svc0.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    svc0:
      match: {macaddress: "02:20:00:00:02:11"}
      set-name: svc0
      addresses: [10.20.1.10/24]
EOF
    sudo chmod 600 /etc/netplan/60-svc0.yaml
    sudo netplan apply
    sudo tee /etc/nftables.conf >/dev/null <<'EOF'
#!/usr/sbin/nft -f
# Only this table is managed here; no "flush ruleset", so other rules stay intact.
table inet ironcloud
delete table inet ironcloud
table inet ironcloud {
    chain input {
        type filter hook input priority 0; policy accept;
        iifname "svc0" ct state established,related accept
        iifname "svc0" meta l4proto { icmp, ipv6-icmp } accept
        iifname "svc0" meta l4proto { tcp, udp } th dport 53 accept
        iifname "svc0" drop
    }
}
EOF
    sudo systemctl enable -q nftables
    sudo systemctl restart nftables
    ip -br addr show svc0
}

stage_bootstrap() {
    log "bootstrap: Docker and host settings via kolla-ansible"
    config
    kolla bootstrap-servers -i "$INV"
}

stage_ceph() {
    log "ceph: cluster, OSDs, pools, client keys"
    if [ ! -f /etc/ceph/ceph.conf ]; then
        sudo cephadm --image "$CEPH_IMAGE" bootstrap --mon-ip "$MON_IP" --skip-monitoring-stack --skip-dashboard
    fi
    # cephadm logs in as root; replace cloud-init's "login as ubuntu" stub.
    for n in "${NODES[@]}"; do
        ssh "$n" 'sudo tee /root/.ssh/authorized_keys >/dev/null' < <(sudo cat /etc/ceph/ceph.pub)
    done
    sudo ceph orch host add cmp1 10.20.0.12
    sudo ceph orch host add cmp2 10.20.0.13
    sudo ceph orch apply mon --placement="ctl1,cmp1,cmp2"
    sudo ceph orch apply mgr --placement="ctl1,cmp1"
    sudo ceph config set osd osd_memory_target_autotune false
    sudo ceph config set osd osd_memory_target 1073741824
    sudo ceph orch apply osd --all-available-devices
    sudo ceph mgr module enable prometheus

    # Admin CLI on every node, so Ceph can be operated while ctl1 is down.
    for n in cmp1 cmp2; do
        ssh "$n" 'sudo add-apt-repository -y cloud-archive:gazpacho >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends ceph-common >/dev/null'
        sudo ceph orch host label add "$n" _admin
    done

    log "ceph: waiting for 3 OSDs"
    for _ in $(seq 60); do
        [ "$(sudo ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_up_osds"])')" = 3 ] && break
        sleep 10
    done
    sudo ceph osd stat

    for pool in images volumes vms; do
        sudo ceph osd pool create "$pool" >/dev/null
        sudo rbd pool init "$pool"
    done

    mkdir -p /etc/kolla/config/{glance,nova,cinder/cinder-volume}
    sudo ceph config generate-minimal-conf | sed 's/^\t//' > /tmp/ceph.conf
    for d in glance nova cinder; do cp /tmp/ceph.conf "/etc/kolla/config/$d/ceph.conf"; done
    # /etc/kolla belongs to $USER (stage_deps): only ceph needs root, not the redirect.
    # shellcheck disable=SC2024
    sudo ceph auth get-or-create client.glance mon 'profile rbd' osd 'profile rbd pool=images' mgr 'profile rbd pool=images' \
        > /etc/kolla/config/glance/ceph.client.glance.keyring
    # shellcheck disable=SC2024
    sudo ceph auth get-or-create client.cinder mon 'profile rbd' \
        osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
        mgr 'profile rbd pool=volumes, profile rbd pool=vms' \
        > /etc/kolla/config/cinder/cinder-volume/ceph.client.cinder.keyring
    cp /etc/kolla/config/cinder/cinder-volume/ceph.client.cinder.keyring /etc/kolla/config/nova/ceph.client.cinder.keyring
}

stage_openstack() {
    log "openstack: prechecks, deploy, post-deploy"
    config
    # Upstream quay.io images are flagged as test images; fine for a lab, production builds its own.
    kolla prechecks -i "$INV" --use-test-images
    kolla deploy -i "$INV"
    kolla post-deploy -i "$INV"
    mkdir -p ~/.config/openstack
    sudo install -o "$USER" -m 600 /etc/kolla/clouds.yaml ~/.config/openstack/clouds.yaml
}

stages=("$@")
[ ${#stages[@]} -gt 0 ] || stages=(deps prep shared bootstrap ceph openstack)
for s in "${stages[@]}"; do
    declare -F "stage_$s" >/dev/null || { echo "Unknown stage: $s" >&2; exit 1; }
    "stage_$s"
done
log "done: ${stages[*]}"
