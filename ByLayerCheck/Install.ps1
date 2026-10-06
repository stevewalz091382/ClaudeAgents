<#
.SYNOPSIS
    Installs ByLayerCheck for Autodesk Civil 3D.

.DESCRIPTION
    Default: copies ByLayerCheck.bundle into the current user's Autodesk
    ApplicationPlugins folder. Civil 3D loads it automatically at the next
    start; no acaddoc.lsp, support-path or trusted-path changes are needed.

.PARAMETER Scope
    User      (default) %APPDATA%\Autodesk\ApplicationPlugins - no admin rights.
    AllUsers  %ProgramData%\Autodesk\ApplicationPlugins - run as administrator.

.PARAMETER InstallDir
    Install to a custom folder instead (for example a network share). The
    bundle autoloader does not look there, so you must add the line printed
    at the end to acaddoc.lsp and add the folder to Trusted Locations.

.PARAMETER AllowSource
    Install even though ByLayerCheck.vlx has not been built, loading
    src\ByLayerCheck.lsp instead.

.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -Scope AllUsers
.EXAMPLE
    .\Install.ps1 -InstallDir "\\server\cad\ByLayerCheck"
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'AllUsers')]
    [string]$Scope = 'User',
    [string]$InstallDir,
    [switch]$AllowSource
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleSrc  = Join-Path $here 'ByLayerCheck.bundle'
$contents   = Join-Path $bundleSrc 'Contents'
$vlx        = Join-Path $contents 'ByLayerCheck.vlx'
$source     = Join-Path $here 'src\ByLayerCheck.lsp'
$envTarget  = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path $bundleSrc)) { throw "ByLayerCheck.bundle not found next to Install.ps1." }

$useSource = $false
if (-not (Test-Path $vlx)) {
    if ($AllowSource -and (Test-Path $source)) {
        $useSource = $true
        Write-Warning 'ByLayerCheck.vlx not found - installing the .lsp source (-AllowSource).'
    } else {
        throw 'ByLayerCheck.vlx is missing from ByLayerCheck.bundle\Contents. Build it first (see BUILD.md), or run Install.cmd -AllowSource.'
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
        if ($_.Name -eq 'ByLayerCheck-Config.lsp' -and (Test-Path $dest)) {
            Write-Host "Keeping existing $dest"
        } else {
            Copy-Item $_.FullName $dest -Force
        }
    }
    if ($useSource) {
        $srcTo = Join-Path $to 'src'
        New-Item -ItemType Directory -Force -Path $srcTo | Out-Null
        Copy-Item $source $srcTo -Force
    }
}

if ($InstallDir) {
    $target = [IO.Path]::GetFullPath($InstallDir)
    Copy-Contents $contents $target
    [Environment]::SetEnvironmentVariable('BYLAYERCHECK_HOME', $target, $envTarget)
    $loader = (Join-Path $target 'ByLayerCheck-Loader.lsp') -replace '\\', '/'
    Write-Host ''
    Write-Host "Installed to $target"
    Write-Host 'Two manual steps are needed for a custom folder:'
    Write-Host "  1. Add this line to acaddoc.lsp:   (load `"$loader`")"
    Write-Host "  2. Add $target to Options > Files > Trusted Locations."
} else {
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramData } else { $env:APPDATA }
    $target = Join-Path $root 'Autodesk\ApplicationPlugins\ByLayerCheck.bundle'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $bundleSrc 'PackageContents.xml') $target -Force
    Copy-Contents $contents (Join-Path $target 'Contents')
    Write-Host "Installed to $target"
}

Write-Host ''
Write-Host 'Done. Start Civil 3D, open a drawing and type BLCHECK-STATUS to confirm.'
