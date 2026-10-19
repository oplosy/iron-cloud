# Downloads the Ubuntu 24.04 cloud image, converts it to a VHDX base disk and builds one
# cloud-init seed ISO per node. No admin needed. Needs qemu-img in the default WSL distro.
# Run with Windows PowerShell 5.1: IMAPI2 stream writing fails under PowerShell 7.
$ErrorActionPreference = 'Stop'
$cfg = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'nodes.psd1')
$images = Join-Path $cfg.Root 'images'
$seeds = Join-Path $cfg.Root 'seeds'
New-Item -ItemType Directory -Force $images, $seeds | Out-Null

function ConvertTo-WslPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

function ConvertTo-ColonMac([string]$Mac) { ($Mac -replace '(..)(?!$)', '$1:').ToLower() }

function Write-LfFile([string]$Path, [string]$Text) {
    # cloud-init needs LF line endings and no BOM; trailing newline keeps /etc/hosts appendable.
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding $false))
}

# --- Base disk ---
$imageName = 'noble-server-cloudimg-amd64.img'
$baseUrl = 'https://cloud-images.ubuntu.com/noble/current'
$qcow = Join-Path $images $imageName
$base = Join-Path $images 'noble-base.vhdx'

if (-not (Test-Path $base)) {
    wsl.exe -- sh -c 'command -v qemu-img >/dev/null'
    if ($LASTEXITCODE) { throw 'qemu-img not found in WSL. Install it with: sudo apt install qemu-utils' }

    curl.exe -fL --retry 3 -o $qcow "$baseUrl/$imageName"
    if ($LASTEXITCODE) { throw "Download failed: $baseUrl/$imageName" }
    $sums = curl.exe -fsSL "$baseUrl/SHA256SUMS"
    if ($LASTEXITCODE) { throw 'Download failed: SHA256SUMS' }
    $line = $sums | Where-Object { $_ -match "\*?$([regex]::Escape($imageName))$" } | Select-Object -First 1
    if (-not $line) { throw "No checksum for $imageName in SHA256SUMS" }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash $qcow -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "Checksum mismatch for ${imageName}: expected $expected, got $actual" }

    wsl.exe -- qemu-img convert -O vhdx -o subformat=dynamic (ConvertTo-WslPath $qcow) (ConvertTo-WslPath $base)
    if ($LASTEXITCODE) { Remove-Item $base -ErrorAction SilentlyContinue; throw 'qemu-img convert failed' }
    Remove-Item $qcow
}

# --- SSH key (lab only, no passphrase) ---
$key = Join-Path $HOME '.ssh\ironcloud_ed25519'
if (-not (Test-Path $key)) {
    New-Item -ItemType Directory -Force (Split-Path $key) | Out-Null
    ssh-keygen.exe -q -t ed25519 -N '""' -C 'ironcloud-lab' -f $key
    if ($LASTEXITCODE) { throw 'ssh-keygen failed' }
}
$pubKey = (Get-Content "$key.pub" -Raw).Trim()

# --- Seed ISOs ---
if (-not ('IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
    public static void Write(object stream, string path, int blockSize, int blocks) {
        var src = (IStream)stream;
        var buf = new byte[blockSize];
        using (var dst = File.Create(path)) {
            for (int i = 0; i < blocks; i++) { src.Read(buf, blockSize, IntPtr.Zero); dst.Write(buf, 0, blockSize); }
        }
    }
}
'@
}

$hosts = ($cfg.Nodes | ForEach-Object { "      $($_.MgmtIp) $($_.Name)" }) -join "`n"
$gateway = $cfg.Switches[0].HostIp
$dns = $cfg.DnsServers -join ', '

foreach ($n in $cfg.Nodes) {
    $dir = Join-Path $seeds $n.Name
    New-Item -ItemType Directory -Force $dir | Out-Null

    Write-LfFile (Join-Path $dir 'meta-data') @"
instance-id: $($n.Name)-v1
local-hostname: $($n.Name)
"@

    Write-LfFile (Join-Path $dir 'user-data') @"
#cloud-config
hostname: $($n.Name)
ssh_pwauth: false
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$pubKey"]
write_files:
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
$hosts
"@

    Write-LfFile (Join-Path $dir 'network-config') @"
version: 2
ethernets:
  mgmt0:
    match: {macaddress: "$(ConvertTo-ColonMac $n.MgmtMac)"}
    set-name: mgmt0
    addresses: [$($n.MgmtIp)/24]
    routes: [{to: default, via: $gateway}]
    nameservers: {addresses: [$dns]}
  ext0:
    match: {macaddress: "$(ConvertTo-ColonMac $n.ProviderMac)"}
    set-name: ext0
    dhcp4: false
"@

    $fs = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fs.FileSystemsToCreate = 3  # ISO9660 + Joliet, keeps lowercase file names
    $fs.VolumeName = 'cidata'
    $fs.Root.AddTree($dir, $false)
    $result = $fs.CreateResultImage()
    [IsoWriter]::Write($result.ImageStream, (Join-Path $seeds "$($n.Name).iso"), $result.BlockSize, $result.TotalBlocks)
}

Write-Host "Base disk: $base"
Write-Host "Seed ISOs: $seeds"
Write-Host "Next: run new-lab.ps1 in an elevated Windows PowerShell."
