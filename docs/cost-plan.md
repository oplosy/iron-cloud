# Cost Plan

**Budget: 0 TRY.** The whole lab runs on the existing laptop. All software is open source.

## Host

| | |
|---|---|
| CPU | i7-11800H, 8 cores / 16 threads |
| RAM | 32 GB (2×16 GB; 2 slots, max 64 GB) |
| Disk | 512 GB NVMe, 152 GB free |
| Hypervisor | Hyper-V (Windows 11 Pro, already running) with nested virtualization |

Hyper-V owns VT-x, which is why Windows reports firmware virtualization as off. Nested VMs need static memory and `Set-VMProcessor -ExposeVirtualizationExtensions $true`.

## Lab: 3 nested nodes in 17 GB

Three nodes are kept because Ceph monitor quorum and the "lose one node" demo need them. Only the control plane is not HA: there is not enough RAM for 3 controllers.

| VM | Roles | vCPU | RAM | Disks (dynamic VHDX) |
|---|---|---|---|---|
| `ctl1` | Kolla control plane (APIs, MariaDB, RabbitMQ, Neutron L3/DHCP), Ceph mon/mgr, 1 OSD | 4 | 9 GB | 40 GB OS + 15 GB OSD |
| `cmp1` | Nova compute, Ceph mon + standby mgr, 1 OSD | 4 | 4 GB | 25 GB OS + 15 GB OSD |
| `cmp2` | Nova compute, Ceph mon, 1 OSD | 4 | 4 GB | 25 GB OS + 15 GB OSD |
| **Total** | | 12 | **17 GB** | 135 GB max, ~80 GB actual |

Windows keeps ~15 GB RAM; close heavy apps before starting the lab. Every node also has a 2 GB swap file as an OOM safety net. Ubuntu Server 24.04 LTS in every VM.

Tuning that makes it fit:
- Ceph: `osd_memory_target = 1 GiB`, pool `size 3 / min_size 2` (one node can fail without losing writes).
- Tenant VMs: CirrOS image, 128–256 MB flavor. Two departments × 2 VMs ≈ 1 GB.
- Network: two vNICs per VM. One is management on a Hyper-V internal switch with NAT (`10.20.0.0/24`), also carrying VXLAN tenant traffic. The other has no IP and is the Neutron external/provider bridge (`10.20.1.0/24`, host side NATed too). Scripts: [`lab/hyperv`](../lab/hyperv).

## OpenStack services

Picked from the [OpenStack project navigator](https://www.openstack.org/software/project-navigator/openstack-components#openstack-services) by what the demo needs.

| Phase | Service | Purpose |
|---|---|---|
| 1 | Keystone | Identity: one project per department, quotas |
| 1 | Glance | VM images |
| 1 | Nova + Placement | VMs, scheduling |
| 1 | Neutron | Isolated tenant networks, routers, security groups |
| 1 | Cinder (Ceph RBD) | Volumes on Ceph |
| 1 | Horizon | Web UI for the demo |
| 2 | Designate | DNS records for department VMs |
| 3 | Prometheus + Grafana (Kolla) | Monitoring |

Out of scope (RAM cost, not needed for the demo): Swift, Heat, Octavia, Magnum, Ironic, Masakari, Ceilometer/Gnocchi/Aodh, Barbican, Trove, Manila.

## What the failure demo can show

| Power off | Expected result |
|---|---|
| `cmp1` | Its tenant VMs stop; Ceph goes `HEALTH_WARN` with degraded PGs but stays writable; `nova evacuate` restarts the VMs on `cmp2` from shared RBD storage; data written before the failure matches its checksum; PGs return to `active+clean` when `cmp1` comes back. |
| `ctl1` | APIs and Horizon go down; running VMs keep running and same-network traffic keeps flowing; routed traffic stops (L3 agent is on `ctl1`). This shows the control plane / data plane split. |

## Optional spend (only if RAM blocks progress)

| Item | TRY |
|---|---|
| Replace one 16 GB module with a used 32 GB DDR4-3200 SODIMM → 48 GB | ~3,000 – 6,000 (unverified) |

Earlier estimates for dedicated hardware (3 mini PCs, ~70,000 TRY) and rented servers are dropped: they cost money and the demo works without them.
