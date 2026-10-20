# Registers the GitOps agent as a Windows scheduled task for the current user: platform/gitops.sh
# once every few minutes while the user is logged on (gh's login and the lab SSH key live in the
# user profile). No admin needed. Output is appended to %USERPROFILE%\ironcloud-logs\gitops.log.
# Usage (Windows PowerShell): powershell -File platform/gitops-task.ps1 [-Minutes 5] [-Remove]
param([int]$Minutes = 5, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$name = 'IronCloud GitOps'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    "Removed scheduled task '$name'."
    return
}

$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) { throw "Git Bash not found at $bash" }
$repo = (Resolve-Path "$PSScriptRoot\..").Path -replace '\\', '/'
# Not under %LOCALAPPDATA%: packaged apps (MSIX) that run this script see a redirected copy of it.
$log = "$env:USERPROFILE\ironcloud-logs\gitops.log"
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
$logUnix = $log -replace '\\', '/'

# No double quotes inside: they would end the -c argument on the Windows command line.
$cmd = "cd '$repo' && echo --- `$(date '+%F %T') >> '$logUnix' && bash platform/gitops.sh once >> '$logUnix' 2>&1"
# conhost --headless: no console window flashing up on every run.
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless `"$bash`" -c `"$cmd`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "IronCloud: plans open department PRs and applies main on the lab (platform/gitops.sh)" -Force | Out-Null
"Registered '$name': every $Minutes min, log $log"
