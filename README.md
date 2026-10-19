# IronCloud

Enterprise private cloud and data center platform.

**Domains:** System Engineering · Network Engineering · Platform Engineering

A platform that provides departments with virtual machines, networks and storage from the company's own data center. A software team requests an environment; the system checks resource quotas, creates an isolated network, boots the machines, applies DNS and access rules, and enrolls them in monitoring and backup.

## Scope

Multi-node virtualization, distributed storage, network isolation between departments, central identity, automated provisioning, capacity management and hardware maintenance processes. Built on OpenStack and Ceph; the original engineering contribution is their deployment, operation and verification.

## Demo

1. Provision an environment for a department.
2. Prove it cannot reach another department's network.
3. Power off a physical node.
4. Show which service was interrupted, how it recovered, and that data integrity held.
