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

.PARAMETER LogSubfolder
    With a shared -LogDir, write each person's logs to their own subfolder:
    user, computer or user-computer (recommended for teams). Sets the
    CUTONCE_LOGSUBFOLDER environment variable.

.PARAMETER BackupDir
    The shared "master" folder for backup copies made before cleanup and by
    CUTONCE-BACKUP. Sets the CUTONCE_BACKUPDIR environment variable.
    Default: Documents\CutOnce Backups (per user).

.PARAMETER AllowSource
    Development builds only: install even though CutOnce.vlx has not been
    built, loading the .lsp sources instead.

.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -Scope AllUsers -LogDir "\\server\cad\CutOnce\Logs"
.EXAMPLE
    .\Install.ps1 -LogDir "\\server\cad\CutOnce\Logs" -LogSubfolder user-computer
.EXAMPLE
    .\Install.ps1 -LogDir "\\server\cad\CutOnce\Logs" -BackupDir "\\server\cad\CutOnce\Backups"
.EXAMPLE
    .\Install.ps1 -InstallDir "D:\CAD\CutOnce"
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'AllUsers')]
    [string]$Scope = 'User',
    [string]$InstallDir,
    [string]$LogDir,
    [ValidateSet('user', 'computer', 'user-computer')]
    [string]$LogSubfolder,
    [string]$BackupDir,
    [switch]$AllowSource
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleSrc  = Join-Path $here 'CutOnce.bundle'
$contents   = Join-Path $bundleSrc 'Contents'
$vlx        = Join-Path $contents 'CutOnce.vlx'
$sourceDir  = Join-Path $here 'src'
$envTarget  = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }
$kbUrl      = 'https://designtovisualization.com/kb-c3d-and-cutonce-assistant/'

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

# Never overwrite an administrator's edited config on reinstall.
function Copy-Contents([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    Get-ChildItem -Path $from -File | ForEach-Object {
        $dest = Join-Path $to $_.Name
        if ($_.Name -eq 'CutOnce-Config.lsp' -and (Test-Path $dest)) {
            Write-Host "Keeping existing $dest"
            # A config written by an earlier build may still name an older
            # knowledge-base page; point it at the current one.
            $text = Get-Content $dest -Raw
            $fixed = $text -replace 'https://designtovisualization\.com/kb-[A-Za-z0-9-]+/?', $kbUrl
            if ($fixed -ne $text) {
                Set-Content -Path $dest -Value $fixed -Encoding Default -NoNewline
                Write-Host "  Learn More links updated to $kbUrl"
            }
            $sample = Join-Path $to 'CutOnce-Config.sample.lsp'
            Copy-Item $_.FullName $sample -Force
            Write-Host "  The full settings list (Control Center defaults, LockedSettings) is in $sample."
            Write-Host '  Copy any you want into your config; missing keys use the built-in defaults.'
        } else {
            Copy-Item $_.FullName $dest -Force
        }
    }
    # the optional label helper (net48 / net8 builds of CutOnceLabels.dll)
    foreach ($sub in 'net48', 'net8') {
        $dllFrom = Join-Path (Join-Path $from $sub) 'CutOnceLabels.dll'
        $dllTo = Join-Path $to $sub
        if (Test-Path $dllTo) { Remove-Item $dllTo -Recurse -Force }
        if (Test-Path $dllFrom) {
            New-Item -ItemType Directory -Force -Path $dllTo | Out-Null
            Copy-Item $dllFrom $dllTo -Force
            Write-Host "Label helper ($sub) installed."
        }
    }
    # never leave sources from an earlier build next to the new ones
    $srcTo = Join-Path $to 'src'
    if (Test-Path $srcTo) { Remove-Item $srcTo -Recurse -Force }
    if ($useSource) {
        # The loader prefers CutOnce.vlx, so a compiled build left by an
        # earlier install would hide the sources being installed now.
        $oldVlx = Join-Path $to 'CutOnce.vlx'
        if (Test-Path $oldVlx) {
            Remove-Item $oldVlx -Force
            Write-Host "Removed $oldVlx from an earlier install so the new version loads."
        }
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
    foreach ($sub in 'net48', 'net8') {
        $dll = Join-Path (Join-Path $target $sub) 'CutOnceLabels.dll'
        if (Test-Path $dll) {
            Write-Host "  3. For the label helper, NETLOAD $dll (net48 = Civil 3D 2021-2024, net8 = 2025+),"
            Write-Host '     or add it to the Startup Suite (APPLOAD > Contents).'
        }
    }
} else {
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramData } else { $env:APPDATA }
    $pluginDir = Join-Path $root 'Autodesk\ApplicationPlugins'
    $target = Join-Path $pluginDir 'CutOnce.bundle'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Contents $contents (Join-Path $target 'Contents')
    # Keep only the label-helper entries whose DLL was built and copied, so
    # Civil 3D never tries to load a missing module.
    [xml]$pkg = Get-Content (Join-Path $bundleSrc 'PackageContents.xml') -Raw
    foreach ($comp in @($pkg.ApplicationPackage.Components)) {
        $entry = $comp.ComponentEntry
        if ($entry.ModuleName -like '*CutOnceLabels.dll' -and
            -not (Test-Path (Join-Path $target ($entry.ModuleName -replace '^\./', '')))) {
            [void]$pkg.ApplicationPackage.RemoveChild($comp)
        }
    }
    $pkg.Save((Join-Path $target 'PackageContents.xml'))
    if (-not (Get-ChildItem (Join-Path $target 'Contents') -Recurse -Filter 'CutOnceLabels.dll' -ErrorAction SilentlyContinue)) {
        Write-Host 'Label helper not included: typed-over labels will show as "could not be checked".'
        Write-Host '  To add it, build dotnet\CutOnceLabels (see its README.md) and reinstall.'
    }
    Write-Host "Installed to $target"
}

if ($LogDir) {
    [Environment]::SetEnvironmentVariable('CUTONCE_LOGDIR', $LogDir, $envTarget)
    New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Log folder set to $LogDir"
}
if ($LogSubfolder) {
    [Environment]::SetEnvironmentVariable('CUTONCE_LOGSUBFOLDER', $LogSubfolder, $envTarget)
    Write-Host "Each person's logs go to a $LogSubfolder subfolder of the log folder"
}

if ($BackupDir) {
    [Environment]::SetEnvironmentVariable('CUTONCE_BACKUPDIR', $BackupDir, $envTarget)
    New-Item -ItemType Directory -Force -Path $BackupDir -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Backup copies go to $BackupDir"
}

Write-Host ''
Write-Host 'Done. Start Civil 3D and type CUTONCE-STATUS to confirm.'
Write-Host 'Each designer chooses what runs for them with CUTONCE (CutOnce Control Center).'
Write-Host 'CAD administrators: see CAD-Admin-Guide.html for watched commands, extra data points and team logs.'
