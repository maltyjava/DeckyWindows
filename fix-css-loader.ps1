<#
.SYNOPSIS
    Detect (and optionally clear) the zombie CEF page that breaks CSS Loader.
.DESCRIPTION
    Symptom: themes drop out for a few seconds and come back, and the theme-store install
    button goes blank. It looks like Decky or CSS Loader crashing and restarting. It is not -
    the loader never restarts.

    Cause: Steam's UI sometimes leaves an orphaned page in its CEF target list - typically a
    duplicate "Menu" - which is still advertised on :8080 but has no live execution context.
    CSS Loader injects into every page target, so it hits that one, waits its full 5s
    Runtime.evaluate timeout, gives up, and retries forever (measured at 10-15 failures per
    minute, continuously). Every cycle disrupts the CSS transaction, hence the blinking.

    Confirmed by timing each target: the healthy ones answer `1+1` in 2-4 ms, the zombie never
    answers at all. Note it is NOT a stale/dead id - the target is present in /json and
    "Connected to tab" succeeds; only evaluation hangs.

    Repair is a full Steam restart. `steam://restartgameui` also clears it, but it comes back
    in desktop mode and (with AnyFSE managing the session) Steam may then exit entirely.
.PARAMETER Repair
    Fully restart Steam into Big Picture after detecting a zombie.
.EXAMPLE
    .\fix-css-loader.ps1
    .\fix-css-loader.ps1 -Repair
#>
[CmdletBinding()]
param([switch]$Repair, [int]$TimeoutMs = 6000)

$ErrorActionPreference = 'Continue'

function Test-Target {
    param([string]$WsUrl)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ws  = New-Object System.Net.WebSockets.ClientWebSocket
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter($TimeoutMs)
        $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).Wait()
        $m = @{ id = 1; method = 'Runtime.evaluate'
                params = @{ expression = '1+1'; returnByValue = $true } } | ConvertTo-Json -Depth 5 -Compress
        $b = [Text.Encoding]::UTF8.GetBytes($m)
        $ws.SendAsync((New-Object System.ArraySegment[byte] (,$b)),
            [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
        $buf = New-Object byte[] 8192
        $r = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] (,$buf)), $cts.Token)
        $r.Wait()
        $ws.Dispose()
        $sw.Stop()
        return @{ ok = $true; ms = $sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop()
        return @{ ok = $false; ms = $sw.ElapsedMilliseconds }
    }
}

try {
    $targets = Invoke-RestMethod 'http://localhost:8080/json' -TimeoutSec 8
} catch {
    Write-Warning "Steam's CEF endpoint (:8080) is unreachable - is Steam running?"
    return
}

"CEF targets: $($targets.Count)"
$zombies = @()
foreach ($t in $targets) {
    if (-not $t.webSocketDebuggerUrl) { continue }
    $res = Test-Target -WsUrl $t.webSocketDebuggerUrl
    $tag = if ($res.ok) { 'ok      ' } else { 'ZOMBIE  ' }
    "  {0} {1,6} ms  [{2}] {3}" -f $tag, $res.ms, $t.type, $t.title
    if (-not $res.ok) { $zombies += $t }
}

if (-not $zombies) {
    "`nNo unresponsive targets. CSS Loader's injection loop is not blocked here."
    return
}

"`n$($zombies.Count) unresponsive target(s) - this is what stalls CSS Loader:"
$zombies | ForEach-Object { "  $($_.id)  [$($_.type)] $($_.title)" }

if (-not $Repair) {
    "`nRe-run with -Repair to restart Steam into Big Picture and clear it."
    "(Closing the target via /json/close does NOT work - it returns 200 'Target is closing'"
    " and the page stays, because it is too wedged to process its own close.)"
    return
}

"`nRestarting Steam..."
Get-Process steam -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Seconds 8
Get-Process steam, steamwebhelper -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 5

$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
$exe = if ($steam) { Join-Path $steam 'steam.exe' } else { 'C:\Program Files (x86)\Steam\Steam.exe' }
Start-Process $exe -ArgumentList 'steam://open/bigpicture'
"launched $exe (big picture); waiting for :8080..."

for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    if (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue) {
        ":8080 listening after $((($i + 1) * 5))s"
        break
    }
}
"re-run without -Repair to confirm every target now responds."
