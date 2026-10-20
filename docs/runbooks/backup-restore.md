# Runbook: back up and restore a department VM

Backups are full exports of an RBD snapshot of each VM's boot volume, gzipped onto the Windows host (`~/ironcloud-backups/<department>/`), so they survive the loss of the whole Ceph cluster. Each file has a `.sha256` next to it. A 1 GB CirrOS volume is ~40 MB.

Run everything below from the repo on the Windows host (Git Bash).

## Back up

```bash
bash platform/backup.sh backup engineering        # every VM in the department
```

The snapshot is taken while the VM runs, so the backup is crash-consistent: what a power cut at that moment would leave on disk. The snapshot is removed after the export (Cinder cannot delete a volume that has snapshots).

## Restore

```bash
bash platform/backup.sh restore engineering web ~/ironcloud-backups/engineering/web-ironcloud-<time>.raw.gz
```

What it does: checks the `.sha256`, stops the VM, renames its current image to `volume-<id>.pre-restore-<time>`, imports the backup under the original name (Cinder and Nova see the same volume), and starts the VM. If the import fails it puts the original image back.

After checking the VM, remove the old image (the command is printed at the end):

```bash
ssh ctl1 sudo rbd rm volumes/volume-<id>.pre-restore-<time>
```

Until it is removed it still references the Glance image it was cloned from, so that image cannot be deleted.

## Test the whole path

```bash
bash platform/backup.sh test finance ledger
```

Writes 4 MB of random data inside the VM, backs up, overwrites the data with zeros, restores, and compares checksums. Writes `reports/<date>-<vm>-restore-test.md` ([last run](../../reports/20261020-1651-ledger-restore-test.md): backup 9 s, restore until SSH 49 s, checksum matched).

## Limits

- Full exports only; no incremental chain (`rbd export-diff`). Fine at this size.
- Only boot volumes of department VMs; no Keystone, Nova or Neutron database backup. The platform itself is rebuilt from the repo ([rebuild runbook](rebuild-lab.md)), department resources from `departments/*.yaml`.
