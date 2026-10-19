# IronCloud

Enterprise private cloud and data center platform.

**Domains:** System Engineering · Network Engineering · Platform Engineering

A platform that provides departments with virtual machines, networks and storage from the company's own data center. A software team requests an environment; the system checks resource quotas, creates an isolated network, boots the machines, applies DNS and access rules, and enrolls them in monitoring.

## Scope

Built on OpenStack (Kolla-Ansible) and Ceph. The original engineering contribution is their deployment, operation and verification:

- Self-service environments: a department request in Git is applied by OpenTofu
- Network isolation between departments, with shared DNS and monitoring reachable from all
- Automated isolation tests and a failure-injection script that reports what broke, how it recovered and whether data stayed intact
- Runbooks for the failures the demo covers

Out of scope and why: see [docs/roadmap.md](docs/roadmap.md#out-of-scope).

## Demo

1. Provision an environment for a department.
2. Prove it cannot reach another department's network.
3. Power off a node.
4. Show which service was interrupted, how it recovered, and that data integrity held.

## Lab

The whole platform runs on one laptop as 3 nested Hyper-V VMs, with no hardware spend. A "physical node failure" is simulated by hard-powering-off a node VM.

- [docs/roadmap.md](docs/roadmap.md): phases and the checks that mark each one done
- [docs/cost-plan.md](docs/cost-plan.md): lab sizing and budget
- [lab/hyperv](lab/hyperv): scripts that create the lab VMs
