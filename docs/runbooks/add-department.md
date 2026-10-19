# Runbook: add a department

A department gets a project, a `<name>-admin` user, quotas, one network/subnet/router, a security group, VMs with floating IPs and a DNS zone `<name>.ironcloud.lab`.

## 1. Write the request

`departments/<name>.yaml` (name: 2-21 chars, lowercase letters, digits, dashes):

```yaml
description: Marketing department
cidr: 192.168.30.0/24          # must not overlap other departments or 10.20.0.0/16
quota:
  instances: 2
  cores: 2
  ram_mb: 512
  volumes: 2
  gigabytes: 2
  floating_ips: 2
vms:
  - name: site
    flavor: m1.tiny            # optional per VM: image (default cirros), disk_gb (default 1)
```

The plan fails, and nothing is created, if:
- the quota exceeds the per-department platform limit (`platform_limits` in `platform/tofu/variables.tf`),
- the VMs need more instances, cores, RAM, volumes or disk than the quota,
- there are more VMs than floating IPs,
- the CIDR is invalid or inside `10.20.0.0/16`.

## 2. Preview, then apply

From the Windows host:

```bash
bash platform/up.sh departments.sh plan
bash platform/up.sh departments.sh
```

Each department is its own OpenTofu workspace (state in `ctl1:~/ironcloud-state`), so a mistake in one file does not touch the others.

## 3. Verify

```bash
bash platform/up.sh isolation-test.sh        # every line PASS
```

Hand the department its credentials (on ctl1):

```bash
cd ~/ironcloud/platform/tofu && TF_DATA_DIR=~/ironcloud-state/.terraform tofu workspace select <name> && TF_DATA_DIR=~/ironcloud-state/.terraform tofu output -raw admin_password
```

## Changing a department

Edit its YAML and apply again. Quota changes apply in place. Adding a VM adds a port, floating IP, server and DNS record.
