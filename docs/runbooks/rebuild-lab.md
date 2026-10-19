# Runbook: rebuild the lab from scratch

Everything is recreated from the repo. Department data is lost.

## 1. Replace the VMs (one elevated Windows PowerShell)

The seed ISOs are attached to the running VMs and locked, so remove the VMs before regenerating seeds:

```powershell
Stop-VM ctl1,cmp1,cmp2 -TurnOff -Force
Remove-VM ctl1,cmp1,cmp2 -Force
Remove-Item -Recurse -Force C:\IronCloud\vms
lab\hyperv\prepare-images.ps1      # seeds; the base disk is downloaded only if missing
lab\hyperv\new-lab.ps1             # reuses the IronCloud-* switches and the IronCloud NAT
```

Then, in Git Bash, forget the old host keys and wait for cloud-init:

```bash
for ip in 10.20.0.11 10.20.0.12 10.20.0.13; do ssh-keygen -R $ip; done
for ip in 10.20.0.11 10.20.0.12 10.20.0.13; do ssh -i ~/.ssh/ironcloud_ed25519 -o StrictHostKeyChecking=accept-new ubuntu@$ip 'cloud-init status --wait'; done
```

## 2. Deploy the platform

```bash
bash platform/up.sh            # deps, prep, shared, bootstrap, ceph, openstack (~25 min)
bash platform/up.sh smoke-test.sh
bash platform/up.sh smoke-test.sh delete
```

The smoke test also creates what departments need: the `public` network, the `cirros` image and the `m1.tiny` flavor. `delete` removes only the smoke VM.

## 3. Departments

```bash
bash platform/up.sh departments.sh
bash platform/up.sh isolation-test.sh
```

The OpenTofu state lives on ctl1 (`~/ironcloud-state`); a rebuilt ctl1 starts with empty state, which matches the empty cloud.

## Known sharp edges

- Do not edit `platform/up.sh` or `deploy.sh` while they run: bash reads scripts as it goes.
- `kolla-ansible prechecks` needs `--use-test-images` (already in `deploy.sh`) because the lab uses upstream quay.io images.
- The Ceph image is pinned to `v20.2.0` to match the 20.2.0 clients; newer images issue keys those clients reject.
