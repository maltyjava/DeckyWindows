<#
.SYNOPSIS
    Run bootstrap.ps1 detached via Task Scheduler so an SSH drop cannot kill the build.
.DESCRIPTION
    A handheld will sleep mid-build, and a foreground SSH command dies with the connection.
    Task Scheduler owns the process instead, so the build survives disconnects. Poll the log
    to follow progress; re-running is safe because bootstrap.ps1 is idempotent.
#>
[CmdletBinding()]
param([string]$Ref, [string]$Script = 'bootstrap.ps1')

$ErrorActionPreference = 'Stop'
$TASK = 'Decky Bootstrap'
$log  = Join-Path $env:USERPROFILE 'decky-bootstrap.log'
$ps1  = Join-Path $env:USERPROFILE $Script

if (-not (Test-Path $ps1)) { throw "missing $ps1" }
Remove-Item $log -Force -ErrorAction SilentlyContinue

$argline = "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`""
if ($Ref) { $argline += " -Ref $Ref" }

# Keep the machine awake for the duration - a sleeping handheld is what killed the last run.
try { powercfg /change standby-timeout-ac 0 | Out-Null } catch { }
try { powercfg /change monitor-timeout-ac 0 | Out-Null } catch { }

$acct = "$env:USERDOMAIN\$env:USERNAME"
try { $sid = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value }
catch {
    $acct = "$env:COMPUTERNAME\$env:USERNAME"
    $sid  = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value
}

$action    = New-ScheduledTaskAction -Execute 'cmd.exe' `
             -Argument "/c powershell $argline > `"$log`" 2>&1"
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$settings.ExecutionTimeLimit = 'PT2H'

Register-ScheduledTask -TaskName $TASK -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TASK
Start-Sleep -Seconds 5
"launched '$TASK' detached; log -> $log"
"state: $((Get-ScheduledTask -TaskName $TASK).State)"
