<#
.SYNOPSIS
    Install Decky Loader on a Windows handheld, from source, idempotently.
.DESCRIPTION
    Installs the toolchain, clones the community Windows wrapper, patches its two
    non-domain-machine bugs, builds upstream decky-loader with Python 3.11, deploys it,
    and registers an elevated run-at-logon task bound by SID.

    Safe to re-run: every step is skipped if already satisfied. This is also the recovery
    path when a Steam client update breaks Decky.

    See README.md for why each workaround exists.
.PARAMETER Ref
    Upstream tag to build. Default: latest upstream stable release.
.PARAMETER SkipToolchain
    Skip the winget installs (Python 3.11 / Node LTS / Git).
.PARAMETER NoStart
    Register the task but do not start Decky.
.EXAMPLE
    .\bootstrap.ps1
    .\bootstrap.ps1 -Ref v3.2.6
#>
[CmdletBinding()]
param(
    [string]$Ref,
    [switch]$SkipToolchain,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

function Step { param([string]$m) Write-Host "[decky] $m" -ForegroundColor Cyan }
function Note { param([string]$m) Write-Host "        $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- preconditions
$id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run elevated. Over SSH, Windows OpenSSH grants admins a full token automatically.'
}

$PY_DIR   = 'C:\Program Files\Python311'
$PY       = Join-Path $PY_DIR 'python.exe'
$NODE_DIR = 'C:\Program Files\nodejs'
$GIT      = 'C:\Program Files\Git\cmd\git.exe'
$REPO     = Join-Path $env:USERPROFILE 'decky-loader-windows'
$HOMEBREW = Join-Path $env:USERPROFILE 'homebrew'
$WRAPPER  = 'https://github.com/Draek2077/decky-loader-windows'
$TASK     = 'Decky Loader'

function Reset-Path {
    # winget installs do not refresh the current session's PATH.
    $env:PATH = "$NODE_DIR;$PY_DIR;$PY_DIR\Scripts;C:\Program Files\Git\cmd;" +
                [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}

# ---------------------------------------------------------------- 1. toolchain
if (-not $SkipToolchain) {
    Step 'Installing toolchain (Python 3.11, Node LTS, Git)'
    # Python 3.11 specifically: watchdog 4.x breaks on 3.13. See README.
    $want = @(
        @{ Id = 'Python.Python.3.11';  Probe = $PY  },
        @{ Id = 'OpenJS.NodeJS.LTS';   Probe = (Join-Path $NODE_DIR 'node.exe') },
        @{ Id = 'Git.Git';             Probe = $GIT }
    )
    foreach ($w in $want) {
        if (Test-Path $w.Probe) { Note "$($w.Id) already present"; continue }
        Note "installing $($w.Id)"
        winget install -e --id $w.Id --scope machine --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
        Reset-Path
        if (-not (Test-Path $w.Probe)) { throw "$($w.Id) not found at $($w.Probe) after install" }
    }
}
Reset-Path
if (-not (Test-Path $PY)) { throw "Python 3.11 missing at $PY (re-run without -SkipToolchain)" }
Note "python : $(& $PY --version 2>&1)"
Note "node   : $(& (Join-Path $NODE_DIR 'node.exe') --version 2>&1)"

# ---------------------------------------------------------------- 2. wrapper repo
if (Test-Path (Join-Path $REPO '.git')) {
    Step "Wrapper repo present, fetching"
    & $GIT -C $REPO fetch --quiet --all 2>&1 | Out-Null
} else {
    Step "Cloning wrapper -> $REPO"
    & $GIT clone --quiet $WRAPPER $REPO 2>&1 | Out-Null
}

# ---------------------------------------------------------------- 3. patch wrapper bugs
Step 'Patching wrapper (positional-splat + WORKGROUP principal)'

# 3a. update.ps1 - array splat binds positionally; only a hashtable binds by name.
$u = Join-Path $REPO 'update.ps1'
$lines = [IO.File]::ReadAllLines($u); $out = [Collections.Generic.List[string]]::new(); $n = 0
foreach ($l in $lines) {
    if     ($l -match "^\s*\`$installArgs\s*=\s*@\(")        { $out.Add('$installArgs = @{ Ref = $Ref; NoBuild = $true }'); $n++ }
    elseif ($l -match "\`$installArgs\s*\+=\s*'-NoStart'")   { $out.Add("if (`$NoStart) { `$installArgs['NoStart'] = `$true }"); $n++ }
    else                                                     { $out.Add($l) }
}
if ($n) { [IO.File]::WriteAllLines($u, $out); Note "update.ps1: $n line(s) patched" } else { Note 'update.ps1: already patched' }

# 3b. lib\common.ps1 - $env:USERDOMAIN is WORKGROUP off-domain and has no SID.
$c = Join-Path $REPO 'lib\common.ps1'
$lines = [IO.File]::ReadAllLines($c); $out = [Collections.Generic.List[string]]::new(); $n = 0
foreach ($l in $lines) {
    if ($l -match '\$user\s*=\s*"\$env:USERDOMAIN') {
        $out.Add('    # $env:USERDOMAIN is ''WORKGROUP'' off-domain (and over SSH) and has no SID.')
        $out.Add('    $user = "$env:USERDOMAIN\$env:USERNAME"')
        $out.Add('    try {')
        $out.Add('        $sid = (New-Object Security.Principal.NTAccount($user)).Translate([Security.Principal.SecurityIdentifier]).Value')
        $out.Add('    } catch {')
        $out.Add('        $user = "$env:COMPUTERNAME\$env:USERNAME"')
        $out.Add('        $sid  = (New-Object Security.Principal.NTAccount($user)).Translate([Security.Principal.SecurityIdentifier]).Value')
        $out.Add('    }')
        $n++
    } elseif ($l -match '-UserId \$user') {
        $out.Add('    $principal = New-ScheduledTaskPrincipal  -UserId $sid -LogonType Interactive -RunLevel Highest'); $n++
    } else { $out.Add($l) }
}
if ($n) { [IO.File]::WriteAllLines($c, $out); Note "common.ps1: $n site(s) patched" } else { Note 'common.ps1: already patched' }

foreach ($f in $u, $c) {
    $err = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$err)
    if ($err.Count) { throw "patch broke $(Split-Path $f -Leaf): $($err[0].Message)" }
}

# ---------------------------------------------------------------- 4. resolve ref
if (-not $Ref) {
    Step 'Resolving latest upstream stable release'
    $Ref = (Invoke-RestMethod 'https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases/latest' `
            -Headers @{ 'User-Agent' = 'DeckyWindows' }).tag_name
}
if ($Ref -match '^[0-9]') { $Ref = "v$Ref" }
Step "Target upstream ref: $Ref"

# ---------------------------------------------------------------- 5. build venv on 3.11
# build.ps1 reuses .build\buildenv if present, and otherwise resolves bare `python` from
# PATH. Pre-seeding guarantees 3.11 and keeps the Store alias out of the picture entirely.
$venv = Join-Path $REPO '.build\buildenv'
$venvPy = Join-Path $venv 'Scripts\python.exe'
$needVenv = $true
if (Test-Path $venvPy) {
    $v = (& $venvPy --version 2>&1) -join ''
    if ($v -match '3\.11\.') { $needVenv = $false; Note "build venv OK ($v)" }
    else { Note "build venv is $v - recreating on 3.11" }
}
if ($needVenv) {
    Step 'Creating build venv on Python 3.11'
    Remove-Item $venv -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Split-Path $venv) | Out-Null
    & $PY -m venv $venv
    if (-not (Test-Path $venvPy)) { throw 'venv creation failed' }
}

# ---------------------------------------------------------------- 6. build
Step "Building decky-loader $Ref (this takes several minutes)"
Push-Location $REPO
try { & (Join-Path $REPO 'build.ps1') -Ref $Ref } finally { Pop-Location }

$dist = Join-Path $REPO 'dist'
foreach ($n in 'PluginLoader.exe','PluginLoader_noconsole.exe') {
    if (-not (Test-Path (Join-Path $dist $n))) { throw "build produced no $n" }
}
Get-ChildItem "$dist\*.exe" | ForEach-Object { Note "built $($_.Name)  $([math]::Round($_.Length/1MB,1)) MB" }

# ---------------------------------------------------------------- 7. deploy
Step 'Deploying'
Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue |
    ForEach-Object { Note "stopping pid=$($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

foreach ($d in 'plugins','services','settings','themes','logs','data') {
    New-Item -ItemType Directory -Force -Path (Join-Path $HOMEBREW $d) | Out-Null
}
$loaderJson = Join-Path $HOMEBREW 'settings\loader.json'
if (-not (Test-Path $loaderJson)) {
    # Decky parses this with Python json, which chokes on a BOM.
    [IO.File]::WriteAllText($loaderJson, '{ "branch": 0, "pluginOrder": [] }', (New-Object Text.UTF8Encoding $false))
    Note 'wrote default loader.json'
}

$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if (-not $steam) { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
if ($steam) {
    $flag = Join-Path $steam '.cef-enable-remote-debugging'
    if (-not (Test-Path $flag)) { New-Item -ItemType File -Path $flag -Force | Out-Null; Note 'enabled Steam CEF remote debugging' }
    else { Note 'Steam CEF remote debugging already enabled' }
} else { Write-Warning 'Steam install not found - set .cef-enable-remote-debugging manually' }

$svc = Join-Path $HOMEBREW 'services'
foreach ($n in 'PluginLoader.exe','PluginLoader_noconsole.exe') {
    Copy-Item (Join-Path $dist $n) (Join-Path $svc $n) -Force
    Note "deployed $n"
}

# ---------------------------------------------------------------- 8. autostart task
Step "Registering autostart task '$TASK'"
$acct = "$env:USERDOMAIN\$env:USERNAME"
try { $sid = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value }
catch {
    $acct = "$env:COMPUTERNAME\$env:USERNAME"
    $sid  = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value
}
Note "principal $acct -> $sid"

$exe       = Join-Path $svc 'PluginLoader_noconsole.exe'
$action    = New-ScheduledTaskAction     -Execute $exe -WorkingDirectory $svc
$trigger   = New-ScheduledTaskTrigger    -AtLogOn -User $acct
$principal = New-ScheduledTaskPrincipal  -UserId $sid -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$settings.ExecutionTimeLimit = 'PT0S'
Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# ---------------------------------------------------------------- 9. start
if ($NoStart) { Step 'Done (-NoStart given; not launching)'; return }

Step 'Starting Decky'
Start-ScheduledTask -TaskName $TASK
Start-Sleep -Seconds 15

$procs = @(Get-Process PluginLoader_noconsole -ErrorAction SilentlyContinue)
$bound = [bool](Get-NetTCPConnection -LocalPort 1337 -State Listen -ErrorAction SilentlyContinue)
Note "processes: $($procs.Count) (expect 2 + 1 per installed plugin)"
Note "port 1337: $(if ($bound) { 'LISTENING' } else { 'NOT LISTENING' })"

if (-not $bound) {
    Write-Warning 'Backend did not bind :1337. Run .\verify.ps1 for the startup traceback.'
    Write-Warning 'If it mentions watchdog / _ThreadHandle, the build used the wrong Python.'
} else {
    Step 'Decky is up. Fully exit Steam from the tray and relaunch to see it in the Quick Access menu.'
}
