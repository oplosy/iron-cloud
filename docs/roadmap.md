# Roadmap

Each phase is done when every check under it passes and can be re-run from the repo. Lab sizing and the zero-budget decision are in [cost-plan.md](cost-plan.md).

## Phase 0 — Lab (done)

- [x] 3 nested Hyper-V VMs (`ctl1`, `cmp1`, `cmp2`) created from [`lab/hyperv`](../lab/hyperv)
- [x] cloud-init done on all nodes; `/dev/kvm` present (nested virtualization works)
- [x] Nodes reach each other by name and reach the internet through host NAT
- [x] Each node has a separate raw disk for a Ceph OSD

## Phase 1 — Platform (4/5)

Kolla-Ansible multinode (`ctl1` control + network, `cmp1`/`cmp2` compute) and Ceph (cephadm, one OSD per node).

- [x] `openstack compute service list` shows `nova-compute` up on `cmp1` and `cmp2`
- [x] `ceph -s` is `HEALTH_OK` with 3 OSDs up/in; RBD pools use `size 3 / min_size 2`
- [x] A CirrOS VM boots from a Ceph-backed volume, gets a floating IP and answers ping from the host ([`platform/smoke-test.sh`](../platform/smoke-test.sh))
- [ ] The whole platform rebuilds from scratch with documented commands only (recreate VMs → deploy). Every stage has run, but not yet as one clean run on fresh VMs.
- [x] `ctl1` RAM is measured after deploy and lowered to measured use + 1 GB (7.2 GB used, OSD growth to 1 GB → 9 GB)

## Phase 2 — Self-service and network isolation (done)

A department asks for an environment by adding `departments/<name>.yaml` (quota, network CIDR, VMs). [`platform/departments.sh`](../platform/departments.sh) applies each file as its own OpenTofu workspace ([`platform/tofu`](../platform/tofu)).

- [x] One apply creates the project, users/roles, quota, network, subnet, router, security groups, VMs and DNS records (Designate)
- [x] A request over quota fails before anything is created (plan-time preconditions; tested with 2 VMs on a 1-instance quota)
- [x] Deleting the YAML and applying removes everything the department had (servers, volumes, ports, network, router, floating IPs, security groups, zone, user, project)
- [x] Shared DNS (`10.20.1.10`, ctl1's `svc0`) resolves department names and the internet for every department
- [x] The platform address reaches department VMs (ICMP, SSH); departments reach the platform address only on DNS and ICMP
- [x] Department A cannot reach department B: ping and TCP to B's private and floating IPs are blocked
- [x] [`platform/isolation-test.sh`](../platform/isolation-test.sh) runs from inside tenant VMs and prints a pass/fail matrix (40 checks, all pass)

How isolation works:

| Path | Result | Enforced by |
|---|---|---|
| Same department, VM → VM | open | Security group rule: remote group = itself |
| Department A → B private IP | blocked | No route: each department has its own router; private ranges are not routed on the provider network |
| Department A → B floating IP | blocked | B's security group admits only its own group and `10.20.1.10`; A arrives as A's router address |
| Department → `10.20.1.10` DNS/ICMP | open | nftables on ctl1 `svc0` |
| Department → `10.20.1.10` anything else | blocked | nftables on ctl1 `svc0` |
| Platform `10.20.1.10` → VM ICMP/SSH | open | Security group rule for `10.20.1.10/32` |

## Phase 3 — Failure demo and operations

Prerequisite: the user running the scripts can control Hyper-V VMs (Hyper-V Administrators group or an elevated shell).

- [ ] A failure script writes test data and its checksum to a volume, hard-powers-off a node, and records a timeline
- [ ] `cmp1` failure report shows: when `nova-compute` was marked down, Ceph `HEALTH_WARN` with degraded PGs while still writable, `nova evacuate` duration, VM back on `cmp2`, checksum match, PGs back to `active+clean` after `cmp1` returns
- [ ] `ctl1` failure report shows: APIs down, running VMs still up, same-network traffic still flowing, routed traffic stopped, recovery time after `ctl1` returns
- [ ] Reports are written to `reports/` as Markdown
- [ ] Prometheus + Grafana dashboards for nodes, Ceph and OpenStack services, scraping department VMs from `10.20.1.10`
- [ ] Runbooks: compute node failure, controller failure, Ceph OSD down, add a department, remove a department, rebuild the lab

## Out of scope

| Item | Reason |
|---|---|
| Physical hardware | Zero budget; a node failure is simulated by hard-powering-off its VM |
| Control plane HA (3 controllers, Galera, keepalived) | Not enough RAM; the `ctl1` failure demo shows the consequence instead |
| Automatic instance HA (Masakari) | Heavy to run; evacuation is manual and timed |
| External identity (LDAP/FreeIPA) | Keystone projects and roles cover per-department access |
| Backups, capacity planning beyond quotas, hardware maintenance processes | Each is a project of its own |
