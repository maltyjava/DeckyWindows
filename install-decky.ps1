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
    Non-interactive: accept defaults, never prompt.
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

$REPO      = 'maltyjava/DeckyWindows'          # where prebuilt binaries are published
$UPSTREAM  = 'SteamDeckHomebrew/decky-loader'
$TASK      = 'Decky Loader'
$DEFAULT   = 'C:\Decky'
$UA        = @{ 'User-Agent' = 'install-decky' }

function Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Info { param($m) Write-Host "    $m" -ForegroundColor Gray }
function Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- elevation
function Test-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  Decky Loader Installer' -ForegroundColor Cyan
    Write-Host '  Administrator rights are required - accept the UAC prompt.' -ForegroundColor Gray
    Write-Host ''
    # Rebuild our own command line. Works whether running as a .ps1 or as the compiled .exe.
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
        Write-Host '  Right-click install_decky.exe and choose "Run as administrator".' -ForegroundColor Gray
        if (-not $Yes) { Read-Host "`n  Press Enter to close" }
    }
    return
}

Write-Host ''
Write-Host '  ============================================================'
Write-Host '   Decky Loader Installer (Windows)'
Write-Host '  ============================================================'

# ---------------------------------------------------------------- install location
if (-not $Path) {
    if ($Yes) {
        $Path = $DEFAULT
    } else {
        Write-Host ''
        Write-Host "  Where should Decky be installed?" -ForegroundColor Cyan
        Write-Host "  This holds plugins, themes, settings and the loader itself." -ForegroundColor Gray
        Write-Host "  Press Enter for the default." -ForegroundColor Gray
        $entered = Read-Host "  Path [$DEFAULT]"
        $Path = if ([string]::IsNullOrWhiteSpace($entered)) { $DEFAULT } else { $entered.Trim('"').Trim() }
    }
}
$Path = [IO.Path]::GetFullPath($Path)
# Only worth flagging if it lands directly in the home root - that is the clutter Decky
# creates by default (~\homebrew). A deliberate path under the profile is fine.
if ($Path -eq (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'homebrew')) {
    Warn 'that is the default home-directory location Decky uses when unconfigured'
}
Step "Install location: $Path"

$services = Join-Path $Path 'services'
New-Item -ItemType Directory -Force -Path $Path | Out-Null

# ---------------------------------------------------------------- target version
Step 'Resolving Decky version'
if (-not $Ref) {
    try {
        $Ref = (Invoke-RestMethod "https://api.github.com/repos/$UPSTREAM/releases/latest" -Headers $UA -TimeoutSec 20).tag_name
    } catch {
        throw "Could not reach GitHub to resolve the latest Decky release: $($_.Exception.Message)"
    }
}
if ($Ref -match '^[0-9]') { $Ref = "v$Ref" }
Ok "target: $Ref"

# ---------------------------------------------------------------- try prebuilt
$gotPrebuilt = $false
if (-not $ForceBuild) {
    Step "Looking for a prebuilt $Ref binary in $REPO"
    try {
        $rels = Invoke-RestMethod "https://api.github.com/repos/$REPO/releases?per_page=30" -Headers $UA -TimeoutSec 20
        $match = $rels | Where-Object { $_.tag_name -eq "decky-$Ref" } | Select-Object -First 1
        if ($match) {
            $need = 'PluginLoader.exe','PluginLoader_noconsole.exe'
            $have = $match.assets | Where-Object { $need -contains $_.name }
            if (@($have).Count -eq 2) {
                New-Item -ItemType Directory -Force -Path $services | Out-Null
                foreach ($a in $have) {
                    Info "downloading $($a.name) ($([math]::Round($a.size/1MB,1)) MB)"
                    Invoke-WebRequest $a.browser_download_url -OutFile (Join-Path $services $a.name) -Headers $UA -TimeoutSec 300 -UseBasicParsing
                }
                $gotPrebuilt = $true
                Ok 'used prebuilt binaries'
            } else {
                Info "release decky-$Ref exists but is missing binaries - will build"
            }
        } else {
            Info "no prebuilt release for $Ref - will build from source"
        }
    } catch {
        Warn "prebuilt lookup failed ($($_.Exception.Message)) - will build from source"
    }
}

# ---------------------------------------------------------------- build from source
if (-not $gotPrebuilt) {
    $PY_DIR = 'C:\Program Files\Python311'
    $PY     = Join-Path $PY_DIR 'python.exe'
    $NODE   = 'C:\Program Files\nodejs'
    $GIT    = 'C:\Program Files\Git\cmd\git.exe'

    function Reset-Path {
        $env:PATH = "$NODE;$PY_DIR;$PY_DIR\Scripts;C:\Program Files\Git\cmd;" +
                    [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }

    Step 'Checking build toolchain'
    # Python 3.11 specifically: decky pins watchdog ^4, which breaks on 3.13's threading
    # rework - it builds fine then dies at startup with "'handle' must be a _ThreadHandle".
    $want = @(
        @{ Id = 'Python.Python.3.11'; Probe = $PY },
        @{ Id = 'OpenJS.NodeJS.LTS';  Probe = (Join-Path $NODE 'node.exe') },
        @{ Id = 'Git.Git';            Probe = $GIT }
    )
    foreach ($w in $want) {
        if (Test-Path $w.Probe) { Info "$($w.Id) present"; continue }
        Info "installing $($w.Id) ..."
        winget install -e --id $w.Id --scope machine --silent `
            --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
        Reset-Path
        if (-not (Test-Path $w.Probe)) { throw "$($w.Id) not found at $($w.Probe) after install" }
    }
    Reset-Path

    $work = Join-Path $Path '.build'
    $src  = Join-Path $work 'decky-loader'
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    Step "Fetching decky-loader $Ref"
    if (Test-Path (Join-Path $src '.git')) {
        & $GIT -C $src fetch --quiet --all --tags --prune 2>&1 | Out-Null
    } else {
        & $GIT clone --quiet --filter=blob:none "https://github.com/$UPSTREAM.git" $src 2>&1 | Out-Null
    }
    & $GIT -C $src checkout --quiet --force $Ref 2>&1 | Out-Null
    Ok "checked out $(& $GIT -C $src rev-parse --short HEAD)"

    Step 'Building frontend'
    # pnpm 9 reads this lockfile (v9.0) and predates the build-script approval gate that
    # pnpm 10+ added, which otherwise stops the install dead.
    Push-Location (Join-Path $src 'frontend')
    try {
        & npm i -g pnpm@9 2>&1 | Out-Null
        & pnpm i --frozen-lockfile 2>&1 | Out-Null
        & pnpm run build 2>&1 | Out-Null
    } finally { Pop-Location }
    Ok 'frontend built'

    Step 'Building backend (PyInstaller - this is the slow part)'
    $venv   = Join-Path $work 'buildenv'
    $vPy    = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $vPy)) { & $PY -m venv $venv }
    & $vPy -m pip install -q -U pip 'poetry-dynamic-versioning[plugin]' poetry pyinstaller 2>&1 | Out-Null

    Push-Location (Join-Path $src 'backend')
    try {
        $env:POETRY_VIRTUALENVS_CREATE = 'false'
        $env:VIRTUAL_ENV               = $venv
        $env:PYTHON_KEYRING_BACKEND    = 'keyring.backends.null.Keyring'
        $env:PATH                      = "$venv\Scripts;$env:PATH"

        & (Join-Path $venv 'Scripts\poetry.exe') install --no-interaction 2>&1 | Out-Null
        & (Join-Path $venv 'Scripts\poetry.exe') dynamic-versioning 2>&1 | Out-Null
        & (Join-Path $venv 'Scripts\pyinstaller.exe') pyinstaller.spec --noconfirm 2>&1 | Out-Null
        $env:DECKY_NOCONSOLE = '1'
        try { & (Join-Path $venv 'Scripts\pyinstaller.exe') pyinstaller.spec --noconfirm 2>&1 | Out-Null }
        finally { Remove-Item Env:\DECKY_NOCONSOLE -ErrorAction SilentlyContinue }
    } finally {
        'POETRY_VIRTUALENVS_CREATE','VIRTUAL_ENV','PYTHON_KEYRING_BACKEND' |
            ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
        Pop-Location
    }

    $built = Join-Path $src 'backend\dist'
    foreach ($n in 'PluginLoader.exe','PluginLoader_noconsole.exe') {
        if (-not (Test-Path (Join-Path $built $n))) { throw "build produced no $n" }
    }
    New-Item -ItemType Directory -Force -Path $services | Out-Null
    Copy-Item (Join-Path $built 'PluginLoader.exe') $services -Force
    Copy-Item (Join-Path $built 'PluginLoader_noconsole.exe') $services -Force
    Ok 'backend built'

    if (-not $KeepBuild) {
        Step 'Cleaning up build tree'
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        Info 'removed .build (use -KeepBuild to keep it for faster rebuilds)'
    }
}

# ---------------------------------------------------------------- stop any running instance
Step 'Stopping any running Decky'
Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
Get-Process PluginLoader, PluginLoader_noconsole -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

# ---------------------------------------------------------------- folder tree + config
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

# ---------------------------------------------------------------- tell decky where it lives
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

$usedPath = $null
if (Test-Path (Join-Path $Path 'logs')) { $usedPath = $Path }

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
    Write-Host '   To update later, just run this installer again - Decky cannot'
    Write-Host '   update itself on Windows.'
} else {
    Warn 'Decky did not bind port 1337.'
    Write-Host "   Run the console build to see why:" -ForegroundColor Gray
    Write-Host "     `"$(Join-Path $services 'PluginLoader.exe')`"" -ForegroundColor Gray
}
Write-Host '  ============================================================'
Write-Host ''

if (-not $Yes) { Read-Host '  Press Enter to close' }
