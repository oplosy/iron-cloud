# Runbook: Ceph OSD down

**Symptom:** `ceph -s` shows `HEALTH_WARN` with `1 osds down` and degraded/undersized PGs. Grafana: "OSDs up" below 3, "Degraded PGs" above 0.

The cluster has one OSD per node and replicated pools with `size 3 / min_size 2`. With one OSD down every PG still has 2 copies, so reads and writes continue. A second OSD down makes PGs inactive: I/O to them blocks until an OSD returns.

Run Ceph commands from any node; every node has the admin keyring (`_admin` label).

## 1. Find the OSD and its host

```bash
sudo ceph health detail
sudo ceph osd tree down          # which osd.N and which host
```

## 2. Host down, or only the OSD?

```bash
ping -c3 <host>
```

- **Host down:** follow [compute-node-failure.md](compute-node-failure.md) or [controller-failure.md](controller-failure.md). The OSD comes back with the host.
- **Host up, OSD daemon down:**

```bash
sudo ceph orch ps --daemon-type osd           # status of each OSD daemon
sudo ceph orch daemon restart osd.<N>
```

If it does not stay up, read its log on that host:

```bash
sudo cephadm logs --name osd.<N> | tail -50
```

## 3. Watch recovery

```bash
sudo ceph -s           # degraded count falls, then HEALTH_OK, all PGs active+clean
```

Measured after a full node power cut ([report](../../reports/20261019-1650-cmp1-failure.md)): OSD down detected after 28 s; OSD back up 2 min after power-on; `HEALTH_OK` 12 s later.

## 4. Disk is dead

Not exercised in this lab. The standard path: `ceph orch osd rm <N> --replace`, swap the disk, and the `all-available-devices` OSD spec recreates the OSD on the new disk.
