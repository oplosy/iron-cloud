# Runbook: controller (ctl1) failure

**Symptom:** OpenStack APIs and Horizon do not answer; `openstack` commands time out. Grafana (on cmp2) shows ctl1 down and the control-plane targets (MariaDB, RabbitMQ, memcached, OpenStack exporter) down. "nova-compute up" shows "API down".

ctl1 runs every API, MariaDB, RabbitMQ, the Neutron L3/DHCP/metadata agents, Designate/bind9, one Ceph mon and one OSD. There is only one controller (no HA, see [roadmap](../roadmap.md#out-of-scope)).

## What keeps working (measured)

From [the report](../../reports/20261019-1711-ctl1-failure.md):

| | During the outage |
|---|---|
| Running VMs | keep running (3/3) |
| VM to VM in the same department, across hosts | no packet lost (VXLAN between computes) |
| Ceph | 2 of 3 mons in quorum, writable; writes stalled ~27 s until ctl1's OSD was marked down |
| Monitoring (Prometheus/Grafana on cmp2) | up, records the outage |

## What stops

- All API calls: no new VMs, no changes, no evacuations.
- Traffic through department routers (internet, floating IPs): the L3 agent is on ctl1. Measured: 478 s without routed traffic, ending ~3 min after ctl1 was back.
- Shared DNS (`10.20.1.10`, bind9 on ctl1): name resolution inside department VMs fails.
- New DHCP leases and metadata.

## 1. Check from a surviving node

```bash
ssh ubuntu@10.20.0.12
sudo ceph -s                     # mon ctl1 out of quorum, osd on ctl1 down, still writable
sudo docker exec nova_libvirt virsh list     # VMs still running
```

## 2. Bring ctl1 back

Power it on (elevated, on the Windows host: `Start-VM ctl1`). Then, from the host, wait for:

```bash
curl -s http://10.20.0.11:5000/v3          # Keystone (~2.5 min after ctl1 boots)
```

and on ctl1:

```bash
export OS_CLOUD=kolla-admin
openstack compute service list              # all "up"   (~3 min after boot)
openstack network agent list                # all alive  (~3 min after boot)
sudo ceph -s                                # HEALTH_OK
```

The L3 agent rebuilds every router namespace on start (`Finished a router update for <id>` in `/var/log/kolla/neutron/neutron-l3-agent.log`, ~12 s per router here). Routed traffic returns when the router is done.

## 3. If an API does not come back

Check the container and its log on ctl1:

```bash
sudo docker ps -a --filter status=exited --format '{{.Names}}'
sudo docker logs --tail 50 <container>
```

If MariaDB refuses to start after a hard power cut (Galera `safe_to_bootstrap: 0`), recover it with Kolla. It did not happen in this lab's two runs:

```bash
~/kolla-venv/bin/kolla-ansible mariadb_recovery -i /etc/kolla/multinode
```

## 4. Check security groups on the computes

After the outage in this lab, one compute kept a stale security-group member set: VMs in the same department could reach each other in one direction only. Run the isolation test:

```bash
bash platform/up.sh isolation-test.sh        # routing, DNS and isolation all PASS again
```

If same-department checks fail, compare the member sets with the real ports and restart the OVS agent on the compute that is missing members (traffic on existing flows continues during the restart):

```bash
sudo docker exec -u root neutron_openvswitch_agent ipset list | grep -E '^Name|^[0-9]'
sudo docker restart neutron_openvswitch_agent
```

Then run the isolation test again.
