# Runbook: rebuild the lab from scratch

Everything is recreated from the repo. Department data is lost.

## 1. Remove the old VMs (elevated Windows PowerShell)

```powershell
Stop-VM ctl1,cmp1,cmp2 -TurnOff
Remove-VM ctl1,cmp1,cmp2 -Force
Remove-Item -Recurse -Force C:\IronCloud\vms
```

Keep `C:\IronCloud\images` (base disk) to skip the download. Keep the `IronCloud-*` switches and the `IronCloud` NAT; `new-lab.ps1` reuses them.

## 2. Recreate the VMs

```bash
powershell.exe -File lab/hyperv/prepare-images.ps1      # seeds; base disk only if missing
```

Then, elevated: `lab\hyperv\new-lab.ps1`. Wait until all three answer SSH:

```bash
for ip in 10.20.0.11 10.20.0.12 10.20.0.13; do ssh -i ~/.ssh/ironcloud_ed25519 ubuntu@$ip 'cloud-init status --wait'; done
```

Remove the old host keys first if SSH complains: `ssh-keygen -R 10.20.0.11` (and .12, .13).

## 3. Deploy the platform

```bash
bash platform/up.sh            # deps, prep, shared, bootstrap, ceph, openstack (~30-40 min)
bash platform/up.sh smoke-test.sh
bash platform/up.sh smoke-test.sh delete
```

## 4. Departments

```bash
bash platform/up.sh departments.sh
bash platform/up.sh isolation-test.sh
```

The OpenTofu state lives on ctl1 (`~/ironcloud-state`); a rebuilt ctl1 starts with empty state, which matches the empty cloud.

## Known sharp edges

- Do not edit `platform/up.sh` or `deploy.sh` while they run: bash reads scripts as it goes.
- The first `kolla-ansible prechecks` needs `--use-test-images` (already in `deploy.sh`) because the lab uses upstream quay.io images.
- The Ceph image is pinned to `v20.2.0` to match the 20.2.0 clients; newer images issue keys those clients reject.
