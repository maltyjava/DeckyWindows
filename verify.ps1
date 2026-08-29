<#
.SYNOPSIS
    Health-check a Decky Loader install on Windows, including real frontend injection.
.DESCRIPTION
    Checks processes, :1337, Steam's CEF endpoint, and then proves the frontend actually
    loaded by evaluating JS in Steam's SharedJSContext over the CEF debugging protocol.
    Process-alive is NOT sufficient evidence - a bad build runs and serves nothing.
.PARAMETER Traceback
    Stop the background loader and run the console build in the foreground to capture the
    startup traceback. Use when :1337 never binds.
#>
[CmdletBinding()]
param([switch]$Traceback)

$ErrorActionPreference = 'Continue'
$HOMEBREW = Join-Path $env:USERPROFILE 'homebrew'
$svc      = Join-Path $HOMEBREW 'services'

function Head { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }

Head 'processes'
$procs = @(Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue)
if ($procs) { $procs | Sort-Object StartTime | ForEach-Object {
        "  $($_.ProcessName) pid=$($_.Id) start=$($_.StartTime.ToString('HH:mm:ss'))" } }
else { '  none running' }
"  total = $($procs.Count)   (5 from one task start is normal)"

Head 'backend :1337'
$c = Get-NetTCPConnection -LocalPort 1337 -State Listen -ErrorAction SilentlyContinue
if ($c) { "  LISTENING on $($c[0].LocalAddress) pid=$($c[0].OwningProcess)" } else { '  NOT listening' }
try {
    $r = Invoke-WebRequest 'http://127.0.0.1:1337' -TimeoutSec 8 -UseBasicParsing
    "  HTTP $($r.StatusCode)"
} catch {
    if ("$($_.Exception.Message)" -match '403') { '  HTTP 403 - healthy (backend is auth-gated)' }
    else { "  $($_.Exception.Message)" }
}

Head 'steam CEF endpoint :8080'
$targets = $null
try {
    $targets = Invoke-RestMethod 'http://localhost:8080/json' -TimeoutSec 8
    "  $($targets.Count) targets"
} catch {
    "  UNREACHABLE: $($_.Exception.Message)"
    "  -> is Steam running, and does <steam>\.cef-enable-remote-debugging exist?"
}

Head 'frontend injection (JS eval in SharedJSContext)'
function Invoke-CdpEval {
    param([string]$WsUrl, [string]$Expression)
    $ws  = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(10000)
    $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).Wait()
    $msg = @{ id = 1; method = 'Runtime.evaluate'
              params = @{ expression = $Expression; returnByValue = $true } } |
           ConvertTo-Json -Depth 6 -Compress
    $b = [Text.Encoding]::UTF8.GetBytes($msg)
    $ws.SendAsync((New-Object System.ArraySegment[byte] (,$b)),
                  [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
    $buf = New-Object byte[] 65536
    $sb  = New-Object Text.StringBuilder
    do {
        $res = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] (,$buf)), $cts.Token)
        $res.Wait()
        [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Result.Count))
    } while (-not $res.Result.EndOfMessage)
    $ws.Dispose()
    $sb.ToString()
}

$expr = @'
(function () {
  var dpl = window.DeckyPluginLoader || window.deckyPluginLoader;
  return JSON.stringify({
    deckyGlobals: Object.keys(window).filter(function (k) { return /decky/i.test(k); }),
    loaderPresent: !!dpl,
    pluginCount: dpl && dpl.plugins ? dpl.plugins.length : null
  });
})()
'@

$found = $false
foreach ($t in $targets) {
    if (-not $t.webSocketDebuggerUrl) { continue }
    try {
        $o = (Invoke-CdpEval -WsUrl $t.webSocketDebuggerUrl -Expression $expr) | ConvertFrom-Json
        $v = $o.result.result.value
        if ($v -and ($v | ConvertFrom-Json).loaderPresent) {
            "  [$($t.type)] $($t.title)"
            "    $v"
            $found = $true
        }
    } catch { }
}
if (-not $found) { '  Decky globals NOT found in any CEF target - frontend did not inject' }

Head 'autostart task'
$task = Get-ScheduledTask -TaskName 'Decky Loader' -ErrorAction SilentlyContinue
if ($task) {
    $i = Get-ScheduledTaskInfo -TaskName 'Decky Loader'
    "  state=$($task.State)  userId=$($task.Principal.UserId)  runLevel=$($task.Principal.RunLevel)"
    "  lastRun=$($i.LastRunTime)  lastResult=$($i.LastTaskResult)"
} else { '  NOT REGISTERED' }

Head 'plugins'
$p = @(Get-ChildItem (Join-Path $HOMEBREW 'plugins') -Directory -ErrorAction SilentlyContinue)
if ($p) { $p | ForEach-Object { "  $($_.Name)" } } else { '  none installed' }

Head 'recent log'
$f = Get-ChildItem (Join-Path $HOMEBREW 'logs') -Recurse -File -ErrorAction SilentlyContinue |
     Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($f) {
    "  $($f.Name)"
    $stale = @(Get-Content $f.FullName | Select-String 'Assuming it failed').Count
    if ($stale -gt 3) {
        Write-Warning "  $stale 'Assuming it failed' entries - a plugin is holding stale CEF tab IDs."
        Write-Warning "  Restart Decky (not Steam): schtasks /end /tn `"Decky Loader`" & schtasks /run /tn `"Decky Loader`""
    } else { "  no stale-tab retry loop ($stale hits)" }
    Get-Content $f.FullName -Tail 8 | ForEach-Object { "    $_" }
} else { '  (no logs yet)' }

if ($Traceback) {
    Head 'startup traceback (console build)'
    Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    $o = Join-Path $env:TEMP 'decky-con.out'; $e = Join-Path $env:TEMP 'decky-con.err'
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath (Join-Path $svc 'PluginLoader.exe') -WorkingDirectory $svc `
            -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
    Start-Sleep -Seconds 25
    "  exited: $($proc.HasExited)"
    foreach ($file in @($o, $e)) {
        if ((Test-Path $file) -and (Get-Item $file).Length) {
            "  --- $(Split-Path $file -Leaf) ---"
            Get-Content $file -Tail 40 | ForEach-Object { "    $_" }
        }
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "`n  Restart Decky with: schtasks /run /tn `"Decky Loader`"" -ForegroundColor DarkGray
}
