# Runbook: remove a department

Deletes everything the department has: servers and their boot volumes, ports, floating IPs, router, network, security groups (including Neutron's auto-created `default`), DNS zone, user and project. **Data on the VMs is lost.**

## 1. Back up what the department wants to keep

Export every VM's boot volume to the Windows host ([backup runbook](backup-restore.md)); Cinder snapshots would be deleted with the project:

```bash
bash platform/backup.sh backup <name>
```

## 2. Remove the request and preview

```bash
git switch -c remove-<name> && git rm departments/<name>.yaml && git commit -m "Remove the <name> department"
git push -u origin remove-<name> && gh pr create --fill
bash platform/gitops.sh once                # PR comment: "YAML removed, will be destroyed" with the full list
```

## 3. Apply

Merge the PR and run `bash platform/gitops.sh once` again (or leave `watch` running). Without the agent: `bash platform/up.sh departments.sh`.

`departments.sh` destroys the workspace, deletes the leftover `default` security group by project ID and deletes the workspace.

## 4. Verify nothing is left

```bash
openstack project show <name>                         # "No Project found"
openstack server list --all-projects                  # none of its servers
openstack zone list --all-projects                    # no <name>.ironcloud.lab.
```

Verified in this lab by removing and re-adding `finance`: 21 resources destroyed, no leftover ports, networks, routers, floating IPs or security groups for its project ID.
