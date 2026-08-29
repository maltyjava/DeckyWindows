<#
.SYNOPSIS
    Restart Decky Loader properly.
.DESCRIPTION
    `schtasks /end` does NOT reliably stop Decky: it reports SUCCESS but leaves the loader's
    child processes alive, so the follow-up `/run` cannot take over and the old instance keeps
    running. Measured on the Claw - the task reported LastRunTime 15:46 while the loader
    process was still the one started at 13:36, silently serving stale plugin metadata.

    This kills the whole process tree first, confirms it is gone, then starts the task, and
    reports the new process start time so you can prove it actually restarted.
#>
[CmdletBinding()]
param([int]$WaitSeconds = 20)

$ErrorActionPreference = 'Stop'
$TASK = 'Decky Loader'

Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 4

$left = @(Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue).Count
if ($left) { throw "$left loader process(es) survived the kill - refusing to start a second instance" }

Start-ScheduledTask -TaskName $TASK
Start-Sleep -Seconds $WaitSeconds

$procs = @(Get-Process PluginLoader_noconsole -ErrorAction SilentlyContinue | Sort-Object StartTime)
$bound = [bool](Get-NetTCPConnection -LocalPort 1337 -State Listen -ErrorAction SilentlyContinue)
"processes : $($procs.Count)"
if ($procs) { "started   : $($procs[0].StartTime)" }
"port 1337 : $(if ($bound) { 'LISTENING' } else { 'NOT LISTENING' })"
if (-not $bound) { Write-Warning 'Backend did not bind :1337 - run verify.ps1 -Traceback' }
