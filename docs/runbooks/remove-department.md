# Runbook: remove a department

Deletes everything the department has: servers and their boot volumes, ports, floating IPs, router, network, security groups (including Neutron's auto-created `default`), DNS zone, user and project. **Data on the VMs is lost.**

## 1. Back up what the department wants to keep

There is no automatic backup. Snapshot volumes first if needed:

```bash
export OS_CLOUD=kolla-admin
openstack volume list --project <name>
openstack volume snapshot create --force --volume <volume-id> <name>-final
```

Snapshots belong to the project and are removed with it; copy them out (`openstack image create --volume ...`) if they must survive.

## 2. Remove the request and preview

```bash
git rm departments/<name>.yaml
bash platform/up.sh departments.sh plan     # "YAML removed, will be destroyed" with the full list
```

## 3. Apply

```bash
bash platform/up.sh departments.sh
```

`departments.sh` destroys the workspace, deletes the leftover `default` security group by project ID and deletes the workspace.

## 4. Verify nothing is left

```bash
openstack project show <name>                         # "No Project found"
openstack server list --all-projects                  # none of its servers
openstack zone list --all-projects                    # no <name>.ironcloud.lab.
```

Verified in this lab by removing and re-adding `finance`: 21 resources destroyed, no leftover ports, networks, routers, floating IPs or security groups for its project ID.
