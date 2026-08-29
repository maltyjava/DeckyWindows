<#
.SYNOPSIS
    Pin a Decky plugin so the store will never offer to update over it.
.DESCRIPTION
    Decky decides an update exists in frontend/src/store.tsx:

        compare(remotePlugin?.versions?.[0]?.name, curVer, '>')

    - a strict semver "greater than" against the version it reads from the plugin's
    package.json (backend/decky_loader/plugin/plugin.py: `self.version = package_json["version"]`).
    Raising the local version above anything the store will publish makes that comparison
    permanently false, so no update is offered and no nag appears. The plugin's name is
    untouched, so it looks and behaves normally in the UI.

    Deliberately NOT done with filesystem permissions: Decky's install path uninstalls the
    plugin before extracting the new one, so a denied write mid-install can leave the plugin
    deleted rather than protected.

    This does not stop a deliberate manual reinstall from the store - it stops updates.
.PARAMETER Plugin
    Plugin directory name under ~/homebrew/plugins (e.g. decky-steamgriddb).
.PARAMETER PinnedVersion
    Version to write. Default 999.0.0 - valid semver, above any real release.
.PARAMETER Unpin
    Restore the original version recorded when the pin was applied.
.EXAMPLE
    .\pin-plugin.ps1 -Plugin decky-steamgriddb
    .\pin-plugin.ps1 -Plugin decky-steamgriddb -Unpin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Plugin,
    [string]$PinnedVersion = '999.0.0',
    [switch]$Unpin
)

$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:USERPROFILE "homebrew\plugins\$Plugin"
if (-not (Test-Path $dir)) { throw "plugin not found: $dir" }

$pkgPath   = Join-Path $dir 'package.json'
$markPath  = Join-Path $dir '.decky-pin.json'
if (-not (Test-Path $pkgPath)) { throw "no package.json in $dir - cannot pin" }

# Decky's json parsing chokes on a BOM, so always write UTF-8 without one.
function Write-Json($path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
}

$pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json

if ($Unpin) {
    if (-not (Test-Path $markPath)) { throw "not pinned (no $markPath)" }
    $mark = Get-Content $markPath -Raw | ConvertFrom-Json
    $pkg.version = $mark.originalVersion
    Write-Json $pkgPath $pkg
    Remove-Item $markPath -Force
    "unpinned $Plugin -> version restored to $($mark.originalVersion)"
    "restart Decky for it to re-read: schtasks /end /tn `"Decky Loader`" & schtasks /run /tn `"Decky Loader`""
    return
}

if (Test-Path $markPath) {
    $mark = Get-Content $markPath -Raw | ConvertFrom-Json
    "already pinned (original was $($mark.originalVersion), pinned $($mark.pinnedAt))"
    "current package.json version: $($pkg.version)"
    return
}

$original = $pkg.version
Write-Json $markPath ([pscustomobject]@{
    plugin          = $Plugin
    originalVersion = $original
    pinnedVersion   = $PinnedVersion
    pinnedAt        = (Get-Date).ToString('s')
    reason          = 'Local patched build; see github.com/maltyjava/DeckyWindows'
})

$pkg.version = $PinnedVersion
Write-Json $pkgPath $pkg

"pinned $Plugin"
"  name            : $($pkg.name)  (unchanged)"
"  version         : $original -> $PinnedVersion"
"  restore with    : .\pin-plugin.ps1 -Plugin $Plugin -Unpin"
"restart Decky for it to re-read: schtasks /end /tn `"Decky Loader`" & schtasks /run /tn `"Decky Loader`""
