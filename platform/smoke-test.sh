#!/usr/bin/env bash
# Runs on ctl1. Phase 1 check: a CirrOS VM boots from a Ceph volume and answers ping on a floating IP.
# Usage: smoke-test.sh          create what is missing, then check
#        smoke-test.sh delete   remove the smoke VM, its volume and floating IP (shared network/image stay)
set -euo pipefail
export OS_CLOUD=kolla-admin
os() { ~/osc-venv/bin/openstack "$@"; }
exists() { os "$1" show "$2" >/dev/null 2>&1; }
log() { echo "==> $*"; }

CIRROS=0.6.3
VM=smoke-vm

if [ "${1:-}" = delete ]; then
    fip=$(os floating ip list --tags smoke -f value -c ID)
    [ -z "$fip" ] || os floating ip delete $fip
    if exists server "$VM"; then
        # Boot volumes made by "server create --boot-from-volume" outlive the server.
        vols=$(os server show "$VM" -f json -c volumes_attached | python3 -c 'import json,sys; print(" ".join(v["id"] for v in json.load(sys.stdin)["volumes_attached"]))')
        os server delete --wait "$VM"
        [ -z "$vols" ] || os volume delete $vols
    fi
    exit 0
fi

# Shared provider network: the Hyper-V "IronCloud-Provider" switch, host is the gateway.
if ! exists network public; then
    log "external network"
    os network create --external --share --provider-network-type flat --provider-physical-network physnet1 public
    os subnet create --network public --subnet-range 10.20.1.0/24 --gateway 10.20.1.1 \
        --allocation-pool start=10.20.1.100,end=10.20.1.199 --no-dhcp public-subnet
fi

if ! exists image cirros; then
    log "cirros $CIRROS image (raw, so Ceph can clone it copy-on-write)"
    tmp=$(mktemp -d)
    base=https://download.cirros-cloud.net/$CIRROS
    curl -fsSL -o "$tmp/cirros.qcow2" "$base/cirros-$CIRROS-x86_64-disk.img"
    curl -fsSL "$base/SHA256SUMS" | grep " cirros-$CIRROS-x86_64-disk.img$" | sed "s|cirros-$CIRROS-x86_64-disk.img|$tmp/cirros.qcow2|" | sha256sum -c -
    command -v qemu-img >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq qemu-utils >/dev/null
    qemu-img convert -O raw "$tmp/cirros.qcow2" "$tmp/cirros.raw"
    os image create --disk-format raw --container-format bare --public --file "$tmp/cirros.raw" cirros
    rm -rf "$tmp"
fi

exists flavor m1.tiny || os flavor create --vcpus 1 --ram 256 --disk 1 m1.tiny

if ! exists network smoke-net; then
    log "smoke tenant network and router"
    os network create smoke-net
    os subnet create --network smoke-net --subnet-range 192.168.100.0/24 --dns-nameserver 1.1.1.1 smoke-subnet
    os router create --external-gateway public smoke-router
    os router add subnet smoke-router smoke-subnet
fi

if ! os security group show smoke >/dev/null 2>&1; then
    os security group create smoke
    os security group rule create --protocol icmp smoke
    os security group rule create --protocol tcp --dst-port 22 smoke
fi

if ! exists server "$VM"; then
    log "boot $VM from a 1 GB volume"
    os server create --flavor m1.tiny --image cirros --boot-from-volume 1 \
        --network smoke-net --security-group smoke --wait "$VM"
fi

fip=$(os floating ip list --tags smoke -f value -c "Floating IP Address")
if [ -z "$fip" ]; then
    fip=$(os floating ip create --tag smoke public -f value -c floating_ip_address)
    os server add floating ip "$VM" "$fip"
fi

log "checks"
status=$(os server show "$VM" -f value -c status)
host=$(os server show "$VM" -f value -c OS-EXT-SRV-ATTR:host)
vol=$(os server show "$VM" -f json -c volumes_attached | python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes_attached"][0]["id"])')
echo "server:   $status on $host"
echo "volume:   $(sudo rbd ls volumes | grep -c "volume-$vol") rbd image in pool 'volumes' for $vol"
echo "ceph:     $(sudo ceph health)"
echo "floating: $fip"
# ctl1 cannot reach the provider network (Windows does not route between the two switches).
echo "Next: ping $fip from the Windows host."
