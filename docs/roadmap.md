# Roadmap

Each phase is done when every check under it passes and can be re-run from the repo. Lab sizing and the zero-budget decision are in [cost-plan.md](cost-plan.md).

## Phase 0 — Lab (done)

- [x] 3 nested Hyper-V VMs (`ctl1`, `cmp1`, `cmp2`) created from [`lab/hyperv`](../lab/hyperv)
- [x] cloud-init done on all nodes; `/dev/kvm` present (nested virtualization works)
- [x] Nodes reach each other by name and reach the internet through host NAT
- [x] Each node has a separate raw disk for a Ceph OSD

## Phase 1 — Platform (done)

Kolla-Ansible multinode (`ctl1` control + network, `cmp1`/`cmp2` compute) and Ceph (cephadm, one OSD per node).

- [x] `openstack compute service list` shows `nova-compute` up on `cmp1` and `cmp2`
- [x] `ceph -s` is `HEALTH_OK` with 3 OSDs up/in; RBD pools use `size 3 / min_size 2`
- [x] A CirrOS VM boots from a Ceph-backed volume, gets a floating IP and answers ping from the host ([`platform/smoke-test.sh`](../platform/smoke-test.sh))
- [x] The whole platform rebuilds from scratch with documented commands only ([rebuild runbook](runbooks/rebuild-lab.md)): fresh VMs, one `platform/up.sh` run (~25 min), smoke test pinged from the host, both departments applied, isolation test 40/40. The clean run caught one bug the stage-by-stage runs had hidden: ssh left stdio non-blocking and ansible-core refused to start; `deploy.sh` now resets it.
- [x] `ctl1` RAM is measured after deploy and lowered to measured use + 1 GB (7.2 GB used, OSD growth to 1 GB → 9 GB; raised to 10 GB in Phase 3 after Designate pushed it into swap)

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

## Phase 3 — Failure demo and operations (done)

[`platform/failure-test.sh`](../platform/failure-test.sh) runs on the Windows host: it cuts a node's power with `sysrq` (no sync, no clean shutdown), records a timeline, checks data integrity and writes a report. Powering the node back on needs Hyper-V rights (UAC prompt).

- [x] A failure script writes test data and its checksum, hard-powers-off a node, and records a timeline
- [x] [`cmp1` report](../reports/20261019-1650-cmp1-failure.md): OSD down at 28 s, Ceph writable while degraded, `nova-compute` down at 59 s, VM rebuilt on `cmp2` from its Ceph volume and reachable at 113 s, checksums match, `HEALTH_OK` 12 s after the OSD returned
- [x] [`ctl1` report](../reports/20261019-1711-ctl1-failure.md): APIs down, VMs kept running, east-west traffic lost 0 of 513 pings, routed traffic down until the L3 agent rebuilt the router, 27 s disk stall until Ceph marked ctl1's OSD down, monitoring stayed up
- [x] Re-runs on 2026-10-20 with `ceph -s` snapshots in the report: [`cmp1`](../reports/20261020-1534-cmp1-failure.md) (VM reachable on `cmp2` at 114 s), [`ctl1`](../reports/20261020-1547-ctl1-failure.md) and [`ctl1` again](../reports/20261020-1625-ctl1-failure.md) (0 east-west loss, 29–30 s disk stall, isolation test passed after recovery)
- [x] Reports are written to [`reports/`](../reports) as Markdown, with operator notes on what the numbers mean
- [x] Prometheus + Grafana on `cmp2` (so they survive a controller failure) with the [IronCloud overview](../platform/grafana/ironcloud-overview.json) dashboard: nodes, Ceph, OpenStack services and department VMs (libvirt exporter, labelled by project)
- [x] Runbooks in [`docs/runbooks`](runbooks): [compute node failure](runbooks/compute-node-failure.md), [controller failure](runbooks/controller-failure.md), [Ceph OSD down](runbooks/ceph-osd-down.md), [add a department](runbooks/add-department.md), [remove a department](runbooks/remove-department.md), [rebuild the lab](runbooks/rebuild-lab.md)

Findings the tests surfaced (now handled in scripts and runbooks):

| Finding | Handling |
|---|---|
| Compute API 2.95+ leaves an evacuated server SHUTOFF | Runbook and script start it explicitly after checking it |
| First live migration back after an evacuation fails with `DestinationDiskExists` | Retry; manual cleanup step documented |
| After the controller outage one compute kept a stale security-group member set (same-department traffic one-way) | Isolation test after recovery; restart the OVS agent on that compute |
| Writes stall ~27 s when a node with an OSD dies | Expected Ceph behaviour (heartbeat grace); documented |

## Out of scope

| Item | Reason |
|---|---|
| Physical hardware | Zero budget; a node failure is simulated by hard-powering-off its VM |
| Control plane HA (3 controllers, Galera, keepalived) | Not enough RAM; the `ctl1` failure demo shows the consequence instead |
| Automatic instance HA (Masakari) | Heavy to run; evacuation is manual and timed |
| External identity (LDAP/FreeIPA) | Keystone projects and roles cover per-department access |
| Backups, capacity planning beyond quotas, hardware maintenance processes | Each is a project of its own |
