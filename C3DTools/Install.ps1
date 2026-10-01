<#
.SYNOPSIS
    Installs C3DTools for Autodesk Civil 3D.

.DESCRIPTION
    Default: copies C3DTools.bundle into the current user's Autodesk
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
    Folder for C3DTools logs and reports. Sets the C3DTOOLS_LOGDIR
    environment variable. Default: %LOCALAPPDATA%\C3DTools\Logs.

.PARAMETER AllowSource
    Development builds only: install even though C3DTools.vlx has not been
    built, loading the .lsp sources instead.

.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -Scope AllUsers -LogDir "\\server\cad\C3DTools\Logs"
.EXAMPLE
    .\Install.ps1 -InstallDir "D:\CAD\C3DTools"
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
$bundleSrc  = Join-Path $here 'C3DTools.bundle'
$contents   = Join-Path $bundleSrc 'Contents'
$vlx        = Join-Path $contents 'C3DTools.vlx'
$sourceDir  = Join-Path $here 'src'
$envTarget  = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path $bundleSrc)) { throw "C3DTools.bundle not found next to Install.ps1." }

$useSource = $false
if (-not (Test-Path $vlx)) {
    if ($AllowSource -and (Test-Path (Join-Path $sourceDir 'C3DTools-Core.lsp'))) {
        $useSource = $true
        Write-Warning 'C3DTools.vlx not found - installing development sources (-AllowSource).'
    } else {
        throw 'C3DTools.vlx is missing from C3DTools.bundle\Contents. Build it first (see BUILD.md).'
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
        if ($_.Name -eq 'C3DTools-Config.lsp' -and (Test-Path $dest)) {
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
    [Environment]::SetEnvironmentVariable('C3DTOOLS_HOME', $target, $envTarget)
    $loader = (Join-Path $target 'C3DTools-Loader.lsp') -replace '\\', '/'
    Write-Host ''
    Write-Host "Installed to $target"
    Write-Host 'Two manual steps are needed for a custom folder:'
    Write-Host "  1. Add this line to acaddoc.lsp:   (load `"$loader`")"
    Write-Host "  2. Add $target to Options > Files > Trusted Locations."
} else {
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramData } else { $env:APPDATA }
    $pluginDir = Join-Path $root 'Autodesk\ApplicationPlugins'
    $target = Join-Path $pluginDir 'C3DTools.bundle'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $bundleSrc 'PackageContents.xml') $target -Force
    Copy-Contents $contents (Join-Path $target 'Contents')
    Write-Host "Installed to $target"
}

if ($LogDir) {
    [Environment]::SetEnvironmentVariable('C3DTOOLS_LOGDIR', $LogDir, $envTarget)
    New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log folder set to $LogDir"
}

Write-Host ''
Write-Host 'Done. Start Civil 3D and type C3DTOOLS-STATUS to confirm.'
Write-Host 'MOVE/STRETCH/ROTATE/SCALE interception is OFF; users opt in with C3D-IMPACT-INTERCEPT.'
