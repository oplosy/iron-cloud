#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
# Creates the Hyper-V switches, host NAT and the 3 lab VMs, then starts them.
# Safe to re-run: existing switches, NAT and VMs are left as they are.
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'nodes.psd1')
$base = Join-Path $cfg.Root 'images\noble-base.vhdx'
if (-not (Test-Path $base)) { throw "Base disk not found: $base. Run prepare-images.ps1 first." }

# --- Network ---
foreach ($sw in $cfg.Switches) {
    if (-not (Get-VMSwitch -Name $sw.Name -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $sw.Name -SwitchType Internal | Out-Null
    }
    $alias = "vEthernet ($($sw.Name))"
    if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $sw.HostIp -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $sw.HostIp -PrefixLength 24 | Out-Null
    }
}
if (-not (Get-NetNat -Name 'IronCloud' -ErrorAction SilentlyContinue)) {
    New-NetNat -Name 'IronCloud' -InternalIPInterfaceAddressPrefix $cfg.NatPrefix | Out-Null
}

# --- VMs ---
$vmRoot = Join-Path $cfg.Root 'vms'
foreach ($n in $cfg.Nodes) {
    if (Get-VM -Name $n.Name -ErrorAction SilentlyContinue) { Write-Host "$($n.Name) exists, skipping"; continue }
    $iso = Join-Path $cfg.Root "seeds\$($n.Name).iso"
    if (-not (Test-Path $iso)) { throw "Seed ISO not found: $iso. Run prepare-images.ps1 first." }

    $dir = Join-Path $vmRoot $n.Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $os = Join-Path $dir 'os.vhdx'
    $osd = Join-Path $dir 'osd.vhdx'
    New-VHD -Path $os -ParentPath $base -Differencing | Out-Null
    Resize-VHD -Path $os -SizeBytes ($n.OsDiskGB * 1GB)
    New-VHD -Path $osd -SizeBytes ($n.OsdDiskGB * 1GB) -Dynamic | Out-Null

    $vm = New-VM -Name $n.Name -Generation 2 -MemoryStartupBytes ($n.MemoryGB * 1GB) -VHDPath $os -SwitchName $cfg.Switches[0].Name -Path $vmRoot
    # Nested virtualization needs static memory. ShutDown instead of Save avoids a RAM-sized .vmrs file per VM.
    Set-VM $vm -StaticMemory -ProcessorCount $n.Cpu -AutomaticCheckpointsEnabled $false -AutomaticStopAction ShutDown
    Set-VMProcessor $vm -ExposeVirtualizationExtensions $true
    Set-VMFirmware $vm -SecureBootTemplate MicrosoftUEFICertificateAuthority

    Get-VMNetworkAdapter $vm | Set-VMNetworkAdapter -StaticMacAddress $n.MgmtMac
    Add-VMNetworkAdapter $vm -SwitchName $cfg.Switches[1].Name -StaticMacAddress $n.ProviderMac
    # Nested VMs and OVS bridges send frames with MACs Hyper-V did not assign.
    Get-VMNetworkAdapter $vm | Set-VMNetworkAdapter -MacAddressSpoofing On

    Add-VMHardDiskDrive $vm -Path $osd
    Add-VMDvdDrive $vm -Path $iso
    Set-VMFirmware $vm -FirstBootDevice (Get-VMHardDiskDrive $vm | Where-Object Path -eq $os)
}

# Shared-services NIC on the provider network (DNS for departments); hot-adds to running VMs too.
foreach ($n in $cfg.Nodes | Where-Object { $_.ServiceMac }) {
    if (-not (Get-VMNetworkAdapter -VMName $n.Name | Where-Object MacAddress -eq $n.ServiceMac)) {
        Add-VMNetworkAdapter -VMName $n.Name -SwitchName $cfg.Switches[1].Name -StaticMacAddress $n.ServiceMac
    }
}

Get-VM -Name $cfg.Nodes.Name | Where-Object State -ne 'Running' | Start-VM
Get-VM -Name $cfg.Nodes.Name | Format-Table Name, State, ProcessorCount, @{ n = 'MemoryGB'; e = { $_.MemoryStartup / 1GB } }
Write-Host "SSH: ssh -i ~/.ssh/ironcloud_ed25519 ubuntu@<ip>  ($(($cfg.Nodes | ForEach-Object { "$($_.Name)=$($_.MgmtIp)" }) -join ', '))"
