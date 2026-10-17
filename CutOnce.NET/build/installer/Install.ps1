<#
.SYNOPSIS
    Installs CutOnce (.NET edition) for Autodesk Civil 3D 2021 and later.

.DESCRIPTION
    Default: copies CutOnce.bundle into the current user's Autodesk
    ApplicationPlugins folder. Civil 3D loads it automatically at the next start
    and picks the right DLL for its release (2021-2024 or 2025+). No NETLOAD,
    acaddoc.lsp, support-path or trusted-path changes are needed.

    Replaces the LISP edition of CutOnce in place: same bundle folder, same
    CutOnce-Config.lsp (kept), same designer choices (kept), same logs.

.PARAMETER Scope
    User      (default) %APPDATA%\Autodesk\ApplicationPlugins - no admin rights.
    AllUsers  %ProgramData%\Autodesk\ApplicationPlugins - run as administrator.

.PARAMETER InstallDir
    Install to a custom folder instead (for example a network share). The bundle
    autoloader does not look there, so the installer registers CutOnce to load at
    startup for every AutoCAD / Civil 3D 2021+ profile it finds (registry
    "demand load" keys). Add the folder to Options > Files > Trusted Locations.

.PARAMETER LogDir
    Folder for CutOnce logs. Sets CUTONCE_LOGDIR. Default: %LOCALAPPDATA%\CutOnce\Logs.

.PARAMETER LogSubfolder
    With a shared -LogDir, write each person's logs to their own subfolder:
    user, computer or user-computer (recommended for teams). Sets CUTONCE_LOGSUBFOLDER.

.PARAMETER BackupDir
    The shared "master" folder for backup copies. Sets CUTONCE_BACKUPDIR.
    Default: Documents\CutOnce Backups (per user).

.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -Scope AllUsers -LogDir "\\server\cad\CutOnce\Logs" -LogSubfolder user-computer
.EXAMPLE
    .\Install.ps1 -InstallDir "\\server\cad\CutOnce" -BackupDir "\\server\cad\CutOnce\Backups"
#>
[CmdletBinding()]
param(
    [ValidateSet('User', 'AllUsers')]
    [string]$Scope = 'User',
    [string]$InstallDir,
    [string]$LogDir,
    [ValidateSet('user', 'computer', 'user-computer')]
    [string]$LogSubfolder,
    [string]$BackupDir
)

$ErrorActionPreference = 'Stop'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleSrc = Join-Path $here 'CutOnce.bundle'
$contents  = Join-Path $bundleSrc 'Contents'
$envTarget = if ($Scope -eq 'AllUsers') { 'Machine' } else { 'User' }
$kbUrl     = 'https://designtovisualization.com/kb-c3d-and-cutonce-assistant/'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path (Join-Path $bundleSrc 'PackageContents.xml'))) { throw 'CutOnce.bundle not found next to Install.ps1.' }
$dlls = Get-ChildItem -Path (Join-Path $contents 'Win64') -Filter 'CutOnce.Civil3D.dll' -Recurse -ErrorAction SilentlyContinue
if (-not $dlls) { throw 'CutOnce.Civil3D.dll is missing from CutOnce.bundle\Contents\Win64. Build the package first (build\Build-Bundle.ps1).' }
$has24 = Test-Path (Join-Path $contents 'Win64\R24\CutOnce.Civil3D.dll')
$has25 = Test-Path (Join-Path $contents 'Win64\R25\CutOnce.Civil3D.dll')

if ($Scope -eq 'AllUsers' -and -not (Test-Admin)) {
    throw 'Scope AllUsers needs an elevated (Run as administrator) PowerShell.'
}

if (Get-Process -Name acad -ErrorAction SilentlyContinue) {
    Write-Warning 'Civil 3D is running. Close it before continuing: a loaded CutOnce DLL cannot be replaced.'
    Read-Host 'Press Enter when Civil 3D is closed (or Ctrl+C to stop)'
}

# Copies the Contents folder. Never overwrites an administrator's edited config.
function Copy-Contents([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    # files left by the LISP edition: never needed again
    foreach ($old in 'CutOnce.vlx', 'CutOnce-Loader.lsp') {
        $p = Join-Path $to $old
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Removed $p (LISP edition)" }
    }
    $oldSrc = Join-Path $to 'src'
    if (Test-Path $oldSrc) { Remove-Item $oldSrc -Recurse -Force }

    Get-ChildItem -Path $from -File | ForEach-Object {
        $dest = Join-Path $to $_.Name
        if ($_.Name -eq 'CutOnce-Config.lsp' -and (Test-Path $dest)) {
            Write-Host "Keeping existing $dest"
            $text = Get-Content $dest -Raw
            $fixed = $text -replace 'https://designtovisualization\.com/kb-[A-Za-z0-9-]+/?', $kbUrl
            if ($fixed -ne $text) {
                Set-Content -Path $dest -Value $fixed -Encoding Default -NoNewline
                Write-Host "  Learn More links updated to $kbUrl"
            }
            $sample = Join-Path $to 'CutOnce-Config.sample.lsp'
            Copy-Item $_.FullName $sample -Force
            Write-Host "  New settings (StopOnLock, WarnOfferStop, WarnWhileSelecting, BrandLogo...) are in $sample."
            Write-Host '  Copy any you want into your config; missing keys use the built-in defaults.'
        } else {
            Copy-Item $_.FullName $dest -Force
        }
    }
    $win64 = Join-Path $to 'Win64'
    if (Test-Path $win64) { Remove-Item $win64 -Recurse -Force }
    Copy-Item (Join-Path $from 'Win64') $win64 -Recurse -Force
}

# Registry "demand load" entries, so a custom folder loads at startup in every
# AutoCAD / Civil 3D 2021+ profile: <product key>\Applications\CutOnce
function Register-DemandLoad([string]$target) {
    $hive = if ($Scope -eq 'AllUsers') { 'HKLM:\SOFTWARE\Autodesk\AutoCAD' } else { 'HKCU:\Software\Autodesk\AutoCAD' }
    if (-not (Test-Path $hive)) { Write-Warning "No AutoCAD found under $hive. Start Civil 3D once, then run the installer again."; return }
    $count = 0
    Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSChildName -notmatch '^R(\d+)\.(\d+)$') { return }
        $major = [int]$Matches[1]
        if ($major -lt 24) { return }
        $folder = if ($major -ge 25) { 'R25' } else { 'R24' }
        $dll = Join-Path $target "Win64\$folder\CutOnce.Civil3D.dll"
        if (-not (Test-Path $dll)) { return }
        Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'ACAD-*' } | ForEach-Object {
            $key = Join-Path $_.PSPath 'Applications\CutOnce'
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name 'DESCRIPTION' -Value 'CutOnce for Civil 3D' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name 'LOADER' -Value $dll -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name 'LOADCTRLS' -Value 2 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $key -Name 'MANAGED' -Value 1 -PropertyType DWord -Force | Out-Null
            $count++
        }
    }
    Write-Host "Registered CutOnce to load at startup in $count AutoCAD / Civil 3D profile(s)."
}

if ($InstallDir) {
    $target = [IO.Path]::GetFullPath($InstallDir)
    Copy-Contents $contents $target
    [Environment]::SetEnvironmentVariable('CUTONCE_HOME', $target, $envTarget)
    Register-DemandLoad $target
    Write-Host ''
    Write-Host "Installed to $target"
    Write-Host "Add $target (and its Win64 subfolders) to Options > Files > Trusted Locations."
    Write-Host 'If an older LISP edition was loaded from acaddoc.lsp, delete its (load ".../CutOnce-Loader.lsp") line.'
} else {
    $root = if ($Scope -eq 'AllUsers') { $env:ProgramData } else { $env:APPDATA }
    $target = Join-Path $root 'Autodesk\ApplicationPlugins\CutOnce.bundle'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item (Join-Path $bundleSrc 'PackageContents.xml') $target -Force
    Copy-Contents $contents (Join-Path $target 'Contents')
    # Windows blocks DLLs that came from a downloaded zip; the copies must not carry that mark
    Get-ChildItem $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
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
if (-not $has24) { Write-Warning 'This package has no Civil 3D 2021-2024 build (Win64\R24): it loads in Civil 3D 2025 and later only.' }
if (-not $has25) { Write-Warning 'This package has no Civil 3D 2025+ build (Win64\R25): it loads in Civil 3D 2021-2024 only.' }
Write-Host 'Done. Start Civil 3D and type CUTONCE-STATUS to confirm, then CUTONCE for the Control Center.'
Write-Host 'Type CUTONCE-PREVIEW to see a sample warning in your firm''s branding.'
Write-Host 'CAD administrators: see CAD-Admin-Guide.html for watched commands, extra data points, team logs and branding.'
