# Runbook: compute node failure

**Symptom:** a compute node (`cmp1`/`cmp2`) stops answering; its VMs are unreachable. Grafana "IronCloud overview": node down, one OSD down, "nova-compute up" drops, degraded PGs.

**What keeps working:** Ceph stays writable (pools are `size 3 / min_size 2`, 2 of 3 mons in quorum). VMs on the other compute node are not affected.

**What happens by itself:** `ironcloud-evacuator` on ctl1 ([`platform/evacuator.sh`](../../platform/evacuator.sh)) evacuates the host's VMs once three signals agree for two checks in a row: Nova marks `nova-compute` down, the node does not answer ping, and Ceph has marked all its OSDs down. It disables the host in Nova, restarts the VMs that were running, and re-enables the host when `nova-compute` is up again. It only acts on a node it has seen up since it started, so a node that is still booting while the lab starts is left alone (it logs "not seen up since this service started"). Measured: Ceph marks the OSD down after ~28 s, Nova after ~60 s, the evacuator acts at ~107 s, the VM answers on the other host at ~139 s ([report](../../reports/20261020-1650-cmp1-failure.md)).

Watch it, or check what it did:

```bash
sudo journalctl -u ironcloud-evacuator -t ironcloud-evacuator --since -1h
```

Its two lines of defence against evacuating a VM whose old host still runs: the three-signal check above, and the RBD exclusive lock on every volume (the new host breaks a dead holder's lock and Ceph blocklists it, so a host that comes back cannot write to the moved volume).

The steps below are the manual path: when the evacuator is not running (`systemctl status ironcloud-evacuator`; reinstall with `platform/up.sh evacuator`), when it logged a failure, or when only one compute node is left.

## 1. Confirm the host is really down

Evacuating a VM that is still running on its old host gives two writers on one Ceph volume and corrupts it.

```bash
ping -c3 10.20.0.12                      # from ctl1 or the host: no answer
# On the Windows host (elevated): Get-VM cmp1   -> State Off
```

```bash
export OS_CLOUD=kolla-admin
openstack compute service list --service nova-compute     # State "down" for the failed host
sudo ceph -s                                               # HEALTH_WARN, 1 osd down, degraded PGs
```

Wait for Nova to show `down` (about a minute); evacuate refuses while the service is `up`.

## 2. Evacuate the VMs

```bash
openstack server list --all-projects --host cmp1 -c ID -c Name
openstack server evacuate <server-id>          # no --host: the scheduler picks a target
```

Department VMs boot from Ceph volumes, so Nova rebuilds them on the target from the same disk ("disk on shared storage, evacuating using existing disk").

**Compute API 2.95+ leaves an evacuated server SHUTOFF on purpose.** Check it, then start it:

```bash
openstack server show <server-id> -c status -c OS-EXT-SRV-ATTR:host    # SHUTOFF on the target host
openstack server start <server-id>
```

Measured: evacuate at t+59 s, SHUTOFF on `cmp2` at t+80 s, ACTIVE at t+94 s, floating IP answering at t+113 s.

## 3. Bring the node back

Power the node on. Its containers start on their own (~2 min in this lab). Then check:

```bash
sudo ceph osd tree            # its OSD "up" again
sudo ceph -s                  # HEALTH_OK once backfill finishes (seconds here: little data changed)
openstack compute service list --service nova-compute     # "up"
```

When `nova-compute` starts on the recovered host it deletes the local copies of the instances that were evacuated away.

## 4. Optional: move VMs back

```bash
openstack server migrate --live-migration --host cmp1 --wait <server-id>
```

The **first** live migration back after an evacuation can fail with `DestinationDiskExists` for `/var/lib/nova/instances/<uuid>` on the recovered host (a directory left behind by the evacuation cleanup). The failed migration's rollback removes the directory; run the same command again. If it still fails, remove the directory inside the `nova_compute` container on that host after checking no domain uses it:

```bash
sudo docker exec nova_libvirt virsh list --all          # the instance must not be listed
sudo docker exec nova_compute rm -rf /var/lib/nova/instances/<uuid>
```
