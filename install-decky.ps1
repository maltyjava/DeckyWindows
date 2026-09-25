<#
.SYNOPSIS
    One-shot Decky Loader installer for Windows. Compiled to install_decky.exe.
.DESCRIPTION
    Installs Decky Loader to a location you choose, rather than the home directory.

    Prefers a prebuilt PluginLoader.exe published to this repo's releases; if none matches
    the newest upstream release, it builds from source instead (installing Python 3.11,
    Node and Git via winget as needed).

    Re-run it to update. That is not a convenience - it is the only update path on Windows.
    Decky's in-app updater looks for a release asset named exactly "PluginLoader.exe"
    (backend/decky_loader/updater.py) and upstream only ever publishes the Linux binary
    "PluginLoader", so the in-app update raises "Download url not found" and does nothing.
    The source repo is hardcoded, so it cannot be pointed elsewhere either.

    Everything is logged, and the window is held open on failure - an installer that
    disappears taking its error message with it is useless.
.PARAMETER Path
    Where to install. Default C:\Decky. Decky is told about it via the UNPRIVILEGED_PATH
    environment variable, which is the supported override in localplatformwin.py.
.PARAMETER Ref
    Decky release tag to install, e.g. v3.2.9. Default: newest upstream stable.
.PARAMETER ForceBuild
    Always build from source, even if a matching prebuilt binary exists.
.PARAMETER KeepBuild
    Keep the ~400MB build tree for faster future builds instead of deleting it.
.PARAMETER Yes
    Non-interactive: accept defaults, never prompt, never hold the window open.
.EXAMPLE
    install_decky.exe
    install_decky.exe -Path D:\Decky
    install_decky.exe -Path D:\Decky -Ref v3.2.9 -Yes
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$Ref,
    [switch]$ForceBuild,
    [switch]$KeepBuild,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$REPO     = 'maltyjava/DeckyWindows'
$UPSTREAM = 'SteamDeckHomebrew/decky-loader'
$TASK     = 'Decky Loader'
$DEFAULT  = 'C:\Decky'
$UA       = @{ 'User-Agent' = 'install-decky' }

# ---------------------------------------------------------------- logging
# Put the log beside the exe so it is easy to find; fall back to TEMP.
function Get-SelfDir {
    if ($PSScriptRoot) { return $PSScriptRoot }
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -and -not ($exe -match 'powershell(_ise)?\.exe$|pwsh\.exe$')) {
            return (Split-Path $exe -Parent)
        }
    } catch { }
    return $env:TEMP
}
$LogDir = Get-SelfDir
try { [IO.File]::AppendAllText((Join-Path $LogDir '.wtest'), 'x'); Remove-Item (Join-Path $LogDir '.wtest') -Force }
catch { $LogDir = $env:TEMP }
$LogFile = Join-Path $LogDir 'install_decky.log'
"=== install_decky run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" |
    Out-File $LogFile -Encoding utf8

function Log  { param($m) $m | Out-File $LogFile -Append -Encoding utf8 }
function Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan; Log "==> $m" }
function Info { param($m) Write-Host "    $m" -ForegroundColor Gray;  Log "    $m" }
function Ok   { param($m) Write-Host "    $m" -ForegroundColor Green; Log "    OK: $m" }
function Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow;Log "    WARN: $m" }

# Run a native command, stream its output to the log, and fail loudly on a non-zero exit.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$File,
          [string[]]$Arguments = @(),
          [Parameter(Mandatory)][string]$What)
    Info $What
    Log  "    \$ $File $($Arguments -join ' ')"
    $global:LASTEXITCODE = 0
    # npm, git, pnpm and PyInstaller all write ordinary progress to stderr. Under
    # ErrorActionPreference='Stop' that becomes a *terminating* error even when the command
    # succeeds, so drop to Continue for the call and judge it by its exit code instead.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $File @Arguments 2>&1 | ForEach-Object { Log "       $_" }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE). See $LogFile" }
}

function Hold {
    if (-not $Yes) { Write-Host ''; Read-Host '  Press Enter to close' | Out-Null }
}

# ---------------------------------------------------------------- elevation
function Test-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  Decky Loader Installer' -ForegroundColor Cyan
    Write-Host '  Administrator rights are required - accept the UAC prompt.' -ForegroundColor Gray
    $argList = @()
    if ($Path)       { $argList += @('-Path', "`"$Path`"") }
    if ($Ref)        { $argList += @('-Ref', $Ref) }
    if ($ForceBuild) { $argList += '-ForceBuild' }
    if ($KeepBuild)  { $argList += '-KeepBuild' }
    if ($Yes)        { $argList += '-Yes' }
    try {
        if ($PSCommandPath) {
            $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $argList
            Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs -ErrorAction Stop
        } else {
            $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        }
    } catch {
        Write-Host '  UAC was declined - nothing was installed.' -ForegroundColor Red
        Hold
    }
    return
}

# ================================================================= main
try {

Write-Host ''
Write-Host '  ============================================================'
Write-Host '   Decky Loader Installer (Windows)'
Write-Host '  ============================================================'
Info "log: $LogFile"

# ---------------------------------------------------------------- install location
if (-not $Path) {
    if ($Yes) { $Path = $DEFAULT }
    else {
        Write-Host ''
        Write-Host '  Where should Decky be installed?' -ForegroundColor Cyan
        Write-Host '  This holds plugins, themes, settings and the loader itself.' -ForegroundColor Gray
        $entered = Read-Host "  Path [$DEFAULT]"
        $Path = if ([string]::IsNullOrWhiteSpace($entered)) { $DEFAULT } else { $entered.Trim('"').Trim() }
    }
}
# Strip stray quotes: pasting a quoted path, or passing one through cmd, leaves them
# attached and GetFullPath then rejects the value outright.
$Path = $Path.Trim().Trim('"').Trim("'").Trim()
try {
    $Path = [IO.Path]::GetFullPath($Path)
} catch {
    throw "'$Path' is not a usable path: $($_.Exception.Message)"
}
if ($Path -eq (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'homebrew')) {
    Warn 'that is the default home-directory location Decky uses when unconfigured'
}
Step "Install location: $Path"
$services = Join-Path $Path 'services'
New-Item -ItemType Directory -Force -Path $Path | Out-Null

# ---------------------------------------------------------------- target version
Step 'Resolving Decky version'
if (-not $Ref) {
    $Ref = (Invoke-RestMethod "https://api.github.com/repos/$UPSTREAM/releases/latest" -Headers $UA -TimeoutSec 30).tag_name
}
if ($Ref -match '^[0-9]') { $Ref = "v$Ref" }
Ok "target: $Ref"

# ---------------------------------------------------------------- try prebuilt
$gotPrebuilt = $false
if (-not $ForceBuild) {
    Step "Looking for a prebuilt $Ref binary in $REPO"
    try {
        $rels  = Invoke-RestMethod "https://api.github.com/repos/$REPO/releases?per_page=30" -Headers $UA -TimeoutSec 30
        $match = $rels | Where-Object { $_.tag_name -eq "decky-$Ref" } | Select-Object -First 1
        if ($match) {
            $need = 'PluginLoader.exe','PluginLoader_noconsole.exe'
            $have = @($match.assets | Where-Object { $need -contains $_.name })
            if ($have.Count -eq 2) {
                New-Item -ItemType Directory -Force -Path $services | Out-Null
                foreach ($a in $have) {
                    Info "downloading $($a.name) ($([math]::Round($a.size/1MB,1)) MB)"
                    Invoke-WebRequest $a.browser_download_url -OutFile (Join-Path $services $a.name) `
                        -Headers $UA -TimeoutSec 600 -UseBasicParsing
                }
                $gotPrebuilt = $true
                Ok 'used prebuilt binaries'
            } else { Info "release decky-$Ref is missing binaries - will build" }
        } else { Info "no prebuilt release for $Ref - will build from source" }
    } catch {
        Warn "prebuilt lookup failed: $($_.Exception.Message)"
        Info 'falling back to building from source'
    }
}

# ---------------------------------------------------------------- build from source
if (-not $gotPrebuilt) {
    $PY_DIR  = 'C:\Program Files\Python311'
    $PY      = Join-Path $PY_DIR 'python.exe'
    $NODE    = 'C:\Program Files\nodejs'
    $NPM     = Join-Path $NODE 'npm.cmd'
    $GIT     = 'C:\Program Files\Git\cmd\git.exe'

    function Reset-Path {
        $env:PATH = "$NODE;$PY_DIR;$PY_DIR\Scripts;C:\Program Files\Git\cmd;" +
                    [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }

    Step 'Checking build toolchain'
    # Python 3.11 specifically: decky pins watchdog ^4, which breaks on 3.13's threading
    # rework - it builds fine, then dies at startup with "'handle' must be a _ThreadHandle".
    foreach ($w in @(
        @{ Id = 'Python.Python.3.11'; Probe = $PY },
        @{ Id = 'OpenJS.NodeJS.LTS';  Probe = (Join-Path $NODE 'node.exe') },
        @{ Id = 'Git.Git';            Probe = $GIT })) {
        if (Test-Path $w.Probe) { Info "$($w.Id) present"; continue }
        Invoke-Native -File 'winget' -What "installing $($w.Id)" -Arguments @(
            'install','-e','--id',$w.Id,'--scope','machine','--silent',
            '--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
        Reset-Path
        if (-not (Test-Path $w.Probe)) { throw "$($w.Id) not found at $($w.Probe) after install" }
    }
    Reset-Path
    if (-not (Test-Path $NPM)) { throw "npm not found at $NPM" }

    $work = Join-Path $Path '.build'
    $src  = Join-Path $work 'decky-loader'
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    Step "Fetching decky-loader $Ref"
    if (Test-Path (Join-Path $src '.git')) {
        Invoke-Native -File $GIT -What 'updating existing clone' -Arguments @('-C',$src,'fetch','--all','--tags','--prune','--quiet')
    } else {
        Invoke-Native -File $GIT -What 'cloning upstream' -Arguments @('clone','--quiet','--filter=blob:none',"https://github.com/$UPSTREAM.git",$src)
    }
    Invoke-Native -File $GIT -What "checking out $Ref" -Arguments @('-C',$src,'checkout','--force','--quiet',$Ref)

    Step 'Building frontend'
    # Latest pnpm, as upstream's build-win.yml uses. Do NOT pin to 9: decky ships a
    # frontend/pnpm-workspace.yaml using pnpm 10+ keys (allowBuilds, minimumReleaseAgeExclude),
    # and pnpm 9 rejects that file with "packages field missing or empty". That same file sets
    # allowBuilds.esbuild, which pre-answers pnpm 10+'s build-script approval prompt, so no
    # --dangerously-allow-all-builds is needed.
    #
    # Resolve pnpm's real path rather than trusting PATH: npm installs global shims into its
    # own prefix, which is not necessarily on this process's PATH.
    Invoke-Native -File $NPM -What 'installing pnpm' -Arguments @('i','-g','pnpm','--no-fund','--no-audit')
    $npmPrefix = (& $NPM prefix -g 2>$null | Select-Object -Last 1)
    if ($npmPrefix) { $npmPrefix = $npmPrefix.Trim() }
    $pnpm = $null
    foreach ($c in @(
        (Join-Path $npmPrefix 'pnpm.cmd'),
        (Join-Path $env:APPDATA 'npm\pnpm.cmd'),
        (Join-Path $NODE 'pnpm.cmd'))) {
        if ($c -and (Test-Path $c)) { $pnpm = $c; break }
    }
    if (-not $pnpm) {
        $g = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($g) { $pnpm = $g.Source }
    }
    if (-not $pnpm) { throw "pnpm was installed but could not be located (npm prefix: '$npmPrefix'). See $LogFile" }
    Info "pnpm: $pnpm"

    Push-Location (Join-Path $src 'frontend')
    try {
        Invoke-Native -File $pnpm -What 'installing frontend dependencies' -Arguments @('i','--frozen-lockfile')
        Invoke-Native -File $pnpm -What 'building frontend'               -Arguments @('run','build')
    } finally { Pop-Location }
    Ok 'frontend built'

    Step 'Building backend (PyInstaller - this is the slow part, several minutes)'
    $venv = Join-Path $work 'buildenv'
    $vPy  = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $vPy)) {
        Invoke-Native -File $PY -What 'creating build venv' -Arguments @('-m','venv',$venv)
    }
    Invoke-Native -File $vPy -What 'installing poetry + pyinstaller' -Arguments @(
        '-m','pip','install','-q','-U','pip','poetry-dynamic-versioning[plugin]','poetry','pyinstaller')

    $poetry      = Join-Path $venv 'Scripts\poetry.exe'
    $pyinstaller = Join-Path $venv 'Scripts\pyinstaller.exe'

    Push-Location (Join-Path $src 'backend')
    try {
        $env:POETRY_VIRTUALENVS_CREATE = 'false'
        $env:VIRTUAL_ENV               = $venv
        $env:PYTHON_KEYRING_BACKEND    = 'keyring.backends.null.Keyring'
        $env:PATH                      = "$venv\Scripts;$env:PATH"

        Invoke-Native -File $poetry      -What 'installing backend dependencies' -Arguments @('install','--no-interaction')
        Invoke-Native -File $poetry      -What 'stamping version'                -Arguments @('dynamic-versioning')
        Invoke-Native -File $pyinstaller -What 'building PluginLoader.exe'       -Arguments @('pyinstaller.spec','--noconfirm')
        $env:DECKY_NOCONSOLE = '1'
        try {
            Invoke-Native -File $pyinstaller -What 'building PluginLoader_noconsole.exe' -Arguments @('pyinstaller.spec','--noconfirm')
        } finally { Remove-Item Env:\DECKY_NOCONSOLE -ErrorAction SilentlyContinue }
    } finally {
        'POETRY_VIRTUALENVS_CREATE','VIRTUAL_ENV','PYTHON_KEYRING_BACKEND' |
            ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
        Pop-Location
    }

    $built = Join-Path $src 'backend\dist'
    foreach ($n in 'PluginLoader.exe','PluginLoader_noconsole.exe') {
        if (-not (Test-Path (Join-Path $built $n))) { throw "build produced no $n. See $LogFile" }
    }
    New-Item -ItemType Directory -Force -Path $services | Out-Null
    Copy-Item (Join-Path $built 'PluginLoader.exe') $services -Force
    Copy-Item (Join-Path $built 'PluginLoader_noconsole.exe') $services -Force
    Ok 'backend built'

    if (-not $KeepBuild) {
        Step 'Cleaning up build tree'
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        Info 'removed .build (pass -KeepBuild to keep it for faster rebuilds)'
    }
}

# ---------------------------------------------------------------- stop running instance
Step 'Stopping any running Decky'
Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

# ---------------------------------------------------------------- folders + config
Step 'Preparing Decky folders'
foreach ($d in 'plugins','services','settings','themes','logs','data') {
    New-Item -ItemType Directory -Force -Path (Join-Path $Path $d) | Out-Null
}
$loaderJson = Join-Path $Path 'settings\loader.json'
if (-not (Test-Path $loaderJson)) {
    # Decky parses this with Python json, which chokes on a BOM.
    [IO.File]::WriteAllText($loaderJson, '{ "branch": 0, "pluginOrder": [] }', (New-Object Text.UTF8Encoding $false))
}
Ok "tree ready at $Path"

# ---------------------------------------------------------------- point decky at it
Step 'Pointing Decky at that location'
[Environment]::SetEnvironmentVariable('UNPRIVILEGED_PATH', $Path, 'Machine')
$env:UNPRIVILEGED_PATH = $Path
Ok "UNPRIVILEGED_PATH = $Path (machine-wide)"

# ---------------------------------------------------------------- steam CEF flag
Step 'Enabling Steam CEF remote debugging'
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if (-not $steam) { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
if ($steam) {
    $flag = Join-Path $steam '.cef-enable-remote-debugging'
    if (Test-Path $flag) { Info 'already enabled' }
    else { New-Item -ItemType File -Path $flag -Force | Out-Null; Ok 'enabled (Steam must restart for this)' }
} else {
    Warn 'Steam install not found - create <steam>\.cef-enable-remote-debugging manually'
}

# ---------------------------------------------------------------- autostart task
Step "Registering autostart task '$TASK'"
# $env:USERDOMAIN is WORKGROUP on non-domain machines and has no SID, so resolve properly.
$acct = "$env:USERDOMAIN\$env:USERNAME"
try { $sid = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value }
catch {
    $acct = "$env:COMPUTERNAME\$env:USERNAME"
    $sid  = (New-Object Security.Principal.NTAccount($acct)).Translate([Security.Principal.SecurityIdentifier]).Value
}
$exePath   = Join-Path $services 'PluginLoader_noconsole.exe'
$action    = New-ScheduledTaskAction     -Execute $exePath -WorkingDirectory $services
$trigger   = New-ScheduledTaskTrigger    -AtLogOn -User $acct
$principal = New-ScheduledTaskPrincipal  -UserId $sid -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$settings.ExecutionTimeLimit = 'PT0S'
Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Ok "$acct -> $sid"

# ---------------------------------------------------------------- start + verify
Step 'Starting Decky'
Start-ScheduledTask -TaskName $TASK
Start-Sleep -Seconds 15
$procs = @(Get-Process PluginLoader_noconsole -ErrorAction SilentlyContinue)
$bound = [bool](Get-NetTCPConnection -LocalPort 1337 -State Listen -ErrorAction SilentlyContinue)
Info "processes: $($procs.Count)   port 1337: $(if ($bound) { 'LISTENING' } else { 'NOT LISTENING' })"

Write-Host ''
Write-Host '  ============================================================'
if ($bound) {
    Ok "Decky $Ref is installed and running."
    Write-Host ''
    Write-Host '   Installed to : ' -NoNewline; Write-Host $Path -ForegroundColor Cyan
    Write-Host '   Source       : ' -NoNewline; Write-Host $(if ($gotPrebuilt) { 'prebuilt binary' } else { 'built from source' }) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   Now FULLY EXIT Steam from the system tray (right-click -> Exit,'
    Write-Host '   not just closing the window) and start it again. Decky then appears'
    Write-Host '   in the Quick Access menu.'
    Write-Host ''
    Write-Host '   To update later, run this installer again - Decky cannot update'
    Write-Host '   itself on Windows.'
} else {
    Warn 'Decky installed but did not bind port 1337.'
    Write-Host "   Run the console build to see why:" -ForegroundColor Gray
    Write-Host "     `"$(Join-Path $services 'PluginLoader.exe')`"" -ForegroundColor Gray
}
Write-Host '  ============================================================'
Hold

} catch {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host '   INSTALL FAILED' -ForegroundColor Red
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host ''
    Write-Host "   $($_.Exception.Message)" -ForegroundColor Yellow
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        Write-Host "   at line $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host "   Full log: $LogFile" -ForegroundColor Cyan
    Write-Host ''
    Log '=== FAILED ==='
    Log $_.Exception.Message
    Log ($_.ScriptStackTrace)
    Hold
    exit 1
}
