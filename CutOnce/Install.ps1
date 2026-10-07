<#
.SYNOPSIS
    Installs CutOnce for Autodesk Civil 3D.

.DESCRIPTION
    Default: copies CutOnce.bundle into the current user's Autodesk
    ApplicationPlugins folder. Civil 3D loads it automatically at the next
    start; no acaddoc.lsp, support-path or trusted-path changes are needed.

    CutOnce is ModelWise under its new name. An installed ModelWise is carried
    over the same way: ModelWise-Config.lsp, MODELWISE_LOGDIR, the logs in
    %LOCALAPPDATA%\ModelWise\Logs and each designer's choices move to CutOnce,
    and ModelWise.bundle is deleted.

    CutOnce replaces C3DTools and includes ByLayerCheck. When either is
    installed, the installer carries over what matters and then removes it,
    so nothing runs twice:
      - C3DTools-Config.lsp becomes CutOnce-Config.lsp (if there is none yet)
      - the C3DTOOLS_LOGDIR log folder setting becomes CUTONCE_LOGDIR
      - logs in %LOCALAPPDATA%\C3DTools\Logs are copied to the new folder
      - each designer's choices carry over the first time CutOnce loads
      - C3DTools.bundle and ByLayerCheck.bundle are deleted

.PARAMETER Scope
    User      (default) %APPDATA%\Autodesk\ApplicationPlugins - no admin rights.
    AllUsers  %ProgramData%\Autodesk\ApplicationPlugins - run as administrator.

.PARAMETER InstallDir
    Install to a custom folder instead (for example a network share). The
    bundle autoloader does not look there, so you must add the line printed
    at the end to acaddoc.lsp and add the folder to Trusted Locations.

.PARAMETER LogDir
    Folder for CutOnce logs and reports. Sets the CUTONCE_LOGDIR
    environment variable. Default: %LOCALAPPDATA%\CutOnce\Logs.

.PARAMETER AllowSource
    Development builds only: install even though CutOnce.vlx has not been
    built, loading the .lsp sources instead.

.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -Scope AllUsers -LogDir "\\server\cad\CutOnce\Logs"
.EXAMPLE
    .\Install.ps1 -InstallDir "D:\CAD\CutOnce"
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'AllUsers')]
    [string]$Scope = 'User',
    [string]$InstallDir,
    [string]$LogDir,
    [switch]$AllowSource
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleSrc  = Join-Path $here 'CutOnce.bundle'
$contents   = Join-Path $bundleSrc 'Contents'
$vlx        = Join-Path $contents 'CutOnce.vlx'
$sourceDir  = Join-Path $here 'src'
$envTarget  = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path $bundleSrc)) { throw "CutOnce.bundle not found next to Install.ps1." }

$useSource = $false
if (-not (Test-Path $vlx)) {
    if ($AllowSource -and (Test-Path (Join-Path $sourceDir 'CutOnce-Core.lsp'))) {
        $useSource = $true
        Write-Warning 'CutOnce.vlx not found - installing development sources (-AllowSource).'
    } else {
        throw 'CutOnce.vlx is missing from CutOnce.bundle\Contents. Build it first, or run Install.cmd (which installs the .lsp sources).'
    }
}

if ($Scope -eq 'AllUsers' -and -not (Test-Admin)) {
    throw 'Scope AllUsers needs an elevated (Run as administrator) PowerShell.'
}

if (Get-Process -Name acad -ErrorAction SilentlyContinue) {
    Write-Warning 'Civil 3D is running. Close it before continuing so it picks up the install.'
    Read-Host 'Press Enter when Civil 3D is closed (or Ctrl+C to stop)'
}

# Never overwrite an administrator's edited config on reinstall/upgrade.
function Copy-Contents([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    Get-ChildItem -Path $from -File | ForEach-Object {
        $dest = Join-Path $to $_.Name
        if ($_.Name -eq 'CutOnce-Config.lsp' -and (Test-Path $dest)) {
            Write-Host "Keeping existing $dest"
            $sample = Join-Path $to 'CutOnce-Config.sample.lsp'
            Copy-Item $_.FullName $sample -Force
            Write-Host "  The full settings list (Control Center defaults, LockedSettings) is in $sample."
            Write-Host '  Copy any you want into your config; missing keys use the built-in defaults.'
        } else {
            Copy-Item $_.FullName $dest -Force
        }
    }
    # never leave sources from an earlier build next to the new ones
    $srcTo = Join-Path $to 'src'
    if (Test-Path $srcTo) { Remove-Item $srcTo -Recurse -Force }
    if ($useSource) {
        New-Item -ItemType Directory -Force -Path $srcTo | Out-Null
        Copy-Item (Join-Path $sourceDir '*.lsp') $srcTo -Force
    }
}

# Where the config will live, and whether one is there already (reinstall).
if ($InstallDir) {
    $contentsTarget = [IO.Path]::GetFullPath($InstallDir)
} else {
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramData } else { $env:APPDATA }
    $contentsTarget = Join-Path $root 'Autodesk\ApplicationPlugins\CutOnce.bundle\Contents'
}
$hadConfig = Test-Path (Join-Path $contentsTarget 'CutOnce-Config.lsp')

if ($InstallDir) {
    $target = [IO.Path]::GetFullPath($InstallDir)
    Copy-Contents $contents $target
    [Environment]::SetEnvironmentVariable('CUTONCE_HOME', $target, $envTarget)
    $loader = (Join-Path $target 'CutOnce-Loader.lsp') -replace '\\', '/'
    Write-Host ''
    Write-Host "Installed to $target"
    Write-Host 'Two manual steps are needed for a custom folder:'
    Write-Host "  1. Add this line to acaddoc.lsp:   (load `"$loader`")"
    Write-Host "  2. Add $target to Options > Files > Trusted Locations."
} else {
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramData } else { $env:APPDATA }
    $pluginDir = Join-Path $root 'Autodesk\ApplicationPlugins'
    $target = Join-Path $pluginDir 'CutOnce.bundle'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $bundleSrc 'PackageContents.xml') $target -Force
    Copy-Contents $contents (Join-Path $target 'Contents')
    Write-Host "Installed to $target"
}

# ---- Carry over from ModelWise -----------------------------------------------

$mwBundles = @(
    (Join-Path $env:APPDATA     'Autodesk\ApplicationPlugins\ModelWise.bundle'),
    (Join-Path $env:ProgramData 'Autodesk\ApplicationPlugins\ModelWise.bundle')
)
$mwHomes = @()
foreach ($t in 'User', 'Machine') {
    $h = [Environment]::GetEnvironmentVariable('MODELWISE_HOME', $t)
    if ($h -and (Test-Path (Join-Path $h 'ModelWise-Loader.lsp'))) { $mwHomes += $h }
}

# Config: ModelWise settings become the CutOnce config (same format), unless
# CutOnce already had one.
if (-not $hadConfig) {
    $mwConfigs = @($mwHomes | ForEach-Object { Join-Path $_ 'ModelWise-Config.lsp' }) +
                 @($mwBundles | ForEach-Object { Join-Path $_ 'Contents\ModelWise-Config.lsp' })
    $mwConfig = $mwConfigs | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($mwConfig) {
        $newConfig = Join-Path $contentsTarget 'CutOnce-Config.lsp'
        Copy-Item $newConfig (Join-Path $contentsTarget 'CutOnce-Config.sample.lsp') -Force
        Copy-Item $mwConfig $newConfig -Force
        $hadConfig = $true
        Write-Host "Carried over ModelWise settings from $mwConfig"
    }
}

# A CutOnce config from the earlier C3DTools-based CutOnce build uses the old
# *c3dt:config* name; convert it so its settings keep applying.
$existingConfig = Join-Path $contentsTarget 'CutOnce-Config.lsp'
if ((Test-Path $existingConfig) -and ((Get-Content $existingConfig -Raw) -match '\*c3dt:config\*')) {
    (Get-Content $existingConfig -Raw) -replace '\*c3dt:config\*', '*mwise:config*' |
        Set-Content -Path $existingConfig -Encoding Default
    Write-Host "Converted $existingConfig from the earlier CutOnce format."
}

foreach ($t in 'User', 'Machine') {
    $mwLogs = [Environment]::GetEnvironmentVariable('MODELWISE_LOGDIR', $t)
    if ($mwLogs) {
        if (-not $LogDir -and -not [Environment]::GetEnvironmentVariable('CUTONCE_LOGDIR', $t)) {
            try {
                [Environment]::SetEnvironmentVariable('CUTONCE_LOGDIR', $mwLogs, $t)
                Write-Host "Log folder kept: $mwLogs"
            } catch { Write-Warning "Could not set CUTONCE_LOGDIR ($t) - administrator rights needed?" }
        }
        try { [Environment]::SetEnvironmentVariable('MODELWISE_LOGDIR', $null, $t) } catch { }
    }
}

$mwDefaultLogs = Join-Path $env:LOCALAPPDATA 'ModelWise\Logs'
$coDefaultLogs = Join-Path $env:LOCALAPPDATA 'CutOnce\Logs'
if (-not $LogDir -and (Test-Path $mwDefaultLogs) -and -not (Test-Path $coDefaultLogs)) {
    New-Item -ItemType Directory -Force -Path $coDefaultLogs | Out-Null
    Copy-Item (Join-Path $mwDefaultLogs '*') $coDefaultLogs -Recurse -Force
    Write-Host "Copied existing logs to $coDefaultLogs (the originals are still in $mwDefaultLogs)."
}

foreach ($b in $mwBundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed ModelWise: $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?). Delete it, or CutOnce may not load." }
    }
}
foreach ($h in $mwHomes) {
    Write-Warning "ModelWise is also installed in $h. Remove its (load ...) line from acaddoc.lsp."
}
foreach ($t in 'User', 'Machine') {
    try { [Environment]::SetEnvironmentVariable('MODELWISE_HOME', $null, $t) } catch { }
}

# ---- Carry over from C3DTools ------------------------------------------------

$oldBundles = @(
    (Join-Path $env:APPDATA     'Autodesk\ApplicationPlugins\C3DTools.bundle'),
    (Join-Path $env:ProgramData 'Autodesk\ApplicationPlugins\C3DTools.bundle')
)
$oldHomes = @()
foreach ($t in 'User', 'Machine') {
    $h = [Environment]::GetEnvironmentVariable('C3DTOOLS_HOME', $t)
    if ($h -and (Test-Path (Join-Path $h 'C3DTools-Loader.lsp'))) { $oldHomes += $h }
}

# Config: an administrator's C3DTools settings become the CutOnce config,
# unless CutOnce already had one. The fresh 2.0 file is kept as the sample.
if (-not $hadConfig) {
    $oldConfigs = @($oldHomes | ForEach-Object { Join-Path $_ 'C3DTools-Config.lsp' }) +
                  @($oldBundles | ForEach-Object { Join-Path $_ 'Contents\C3DTools-Config.lsp' })
    $oldConfig = $oldConfigs | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($oldConfig) {
        $newConfig = Join-Path $contentsTarget 'CutOnce-Config.lsp'
        Copy-Item $newConfig (Join-Path $contentsTarget 'CutOnce-Config.sample.lsp') -Force
        (Get-Content $oldConfig -Raw) -replace '\*c3dt:config\*', '*mwise:config*' |
            Set-Content -Path $newConfig -Encoding Default
        Write-Host "Carried over C3DTools settings from $oldConfig"
        Write-Host '  The full 2.0 settings list is in CutOnce-Config.sample.lsp; missing keys use the defaults.'
    }
}

# Log folder setting
foreach ($t in 'User', 'Machine') {
    $oldLogs = [Environment]::GetEnvironmentVariable('C3DTOOLS_LOGDIR', $t)
    if ($oldLogs) {
        if (-not $LogDir -and -not [Environment]::GetEnvironmentVariable('CUTONCE_LOGDIR', $t)) {
            try {
                [Environment]::SetEnvironmentVariable('CUTONCE_LOGDIR', $oldLogs, $t)
                Write-Host "Log folder kept: $oldLogs"
            } catch { Write-Warning "Could not set CUTONCE_LOGDIR ($t) - administrator rights needed?" }
        }
        try { [Environment]::SetEnvironmentVariable('C3DTOOLS_LOGDIR', $null, $t) } catch { }
    }
}

# Default per-user log folder: copy (not move) so nothing is lost.
$oldDefaultLogs = Join-Path $env:LOCALAPPDATA 'C3DTools\Logs'
$newDefaultLogs = Join-Path $env:LOCALAPPDATA 'CutOnce\Logs'
if (-not $LogDir -and (Test-Path $oldDefaultLogs) -and -not (Test-Path $newDefaultLogs)) {
    New-Item -ItemType Directory -Force -Path $newDefaultLogs | Out-Null
    Copy-Item (Join-Path $oldDefaultLogs '*') $newDefaultLogs -Recurse -Force
    Write-Host "Copied existing logs to $newDefaultLogs (the originals are still in $oldDefaultLogs)."
}

# Remove C3DTools so it does not run alongside CutOnce.
foreach ($b in $oldBundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed C3DTools: $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?). Delete it, or every warning shows twice." }
    }
}
foreach ($h in $oldHomes) {
    Write-Warning "C3DTools is also installed in $h. Remove its (load ...) line from acaddoc.lsp, or every warning shows twice."
}
foreach ($t in 'User', 'Machine') {
    try { [Environment]::SetEnvironmentVariable('C3DTOOLS_HOME', $null, $t) } catch { }
}

# ByLayerCheck is now built in: remove the separate add-on so it does not run twice.
foreach ($root in $env:APPDATA, $env:ProgramData) {
    $old = Join-Path $root 'Autodesk\ApplicationPlugins\ByLayerCheck.bundle'
    if (Test-Path $old) {
        try { Remove-Item $old -Recurse -Force; Write-Host "Removed the separate ByLayerCheck add-on: $old" }
        catch { Write-Warning "Could not remove $old (administrator rights needed?). Delete it, or ByLayer checks run twice." }
    }
}
foreach ($t in 'User', 'Machine') {
    $blcHome = [Environment]::GetEnvironmentVariable('BYLAYERCHECK_HOME', $t)
    if ($blcHome -and (Test-Path (Join-Path $blcHome 'ByLayerCheck-Loader.lsp'))) {
        Write-Warning "ByLayerCheck is also installed in $blcHome. Remove its (load ...) line from acaddoc.lsp, or ByLayer checks run twice."
    }
}

if ($LogDir) {
    [Environment]::SetEnvironmentVariable('CUTONCE_LOGDIR', $LogDir, $envTarget)
    New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log folder set to $LogDir"
}

Write-Host ''
Write-Host 'Done. Start Civil 3D and type CUTONCE-STATUS to confirm.'
Write-Host 'Each designer chooses what runs for them with CUTONCE (CutOnce Control Center).'
Write-Host 'MOVE/STRETCH/ROTATE/SCALE interception is OFF until a designer ticks it there.'
