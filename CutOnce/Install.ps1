<#
.SYNOPSIS
    Installs CutOnce for Autodesk Civil 3D.

.DESCRIPTION
    Default: copies CutOnce.bundle into the current user's Autodesk
    ApplicationPlugins folder. Civil 3D loads it automatically at the next
    start; no acaddoc.lsp, support-path or trusted-path changes are needed.

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
        throw 'CutOnce.vlx is missing from CutOnce.bundle\Contents. Build it first (see BUILD.md).'
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
        } else {
            Copy-Item $_.FullName $dest -Force
        }
    }
    if ($useSource) {
        $srcTo = Join-Path $to 'src'
        New-Item -ItemType Directory -Force -Path $srcTo | Out-Null
        Copy-Item (Join-Path $sourceDir '*.lsp') $srcTo -Force
    }
}

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
    # Remove a pre-rename C3DTools bundle so the two never load side by side.
    $old = Join-Path $pluginDir 'C3DTools.bundle'
    if (Test-Path $old) { Remove-Item $old -Recurse -Force; Write-Host "Removed the previous C3DTools.bundle" }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $bundleSrc 'PackageContents.xml') $target -Force
    Copy-Contents $contents (Join-Path $target 'Contents')
    Write-Host "Installed to $target"
}

# Carry logs over from the pre-rename default folder on first install.
$oldLogs = Join-Path $env:LOCALAPPDATA 'C3DTools\Logs'
$newLogs = Join-Path $env:LOCALAPPDATA 'CutOnce\Logs'
if (-not $LogDir -and (Test-Path $oldLogs) -and -not (Test-Path $newLogs)) {
    New-Item -ItemType Directory -Force -Path $newLogs | Out-Null
    Copy-Item (Join-Path $oldLogs '*') $newLogs -Recurse -Force
    Write-Host "Copied existing logs from $oldLogs"
}

if ($LogDir) {
    [Environment]::SetEnvironmentVariable('CUTONCE_LOGDIR', $LogDir, $envTarget)
    New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log folder set to $LogDir"
}

Write-Host ''
Write-Host 'Done. Start Civil 3D and type CUTONCE-STATUS to confirm.'
Write-Host 'MOVE/STRETCH/ROTATE/SCALE interception is OFF; users opt in with C3D-IMPACT-INTERCEPT.'
