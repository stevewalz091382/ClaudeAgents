<#
.SYNOPSIS
    Removes CutOnce (.NET or LISP edition).

.DESCRIPTION
    Deletes CutOnce.bundle from the user and (when elevated) all-users
    ApplicationPlugins folders, removes the custom install folder named by
    CUTONCE_HOME and its registry "demand load" entries, and clears the
    CUTONCE_HOME / CUTONCE_LOGDIR / CUTONCE_LOGSUBFOLDER / CUTONCE_BACKUPDIR
    variables. Each designer's Control Center choices are removed.
    Logs (Health.csv, Xrefs.csv, Events.csv, Opened.csv, Backups.csv) are kept unless
    -RemoveLogs is given; -RemoveLogs never deletes a network, mapped-drive or
    per-person-subfolder log folder, which may hold the whole team's logs.
    Backup copies of drawings are never deleted.
#>
[CmdletBinding()]
param([switch]$RemoveLogs)

$ErrorActionPreference = 'Stop'

if (Get-Process -Name acad -ErrorAction SilentlyContinue) {
    Write-Warning 'Civil 3D is running. Close it first so files are not in use.'
    Read-Host 'Press Enter when Civil 3D is closed (or Ctrl+C to stop)'
}

$bundles = @(
    (Join-Path $env:APPDATA     'Autodesk\ApplicationPlugins\CutOnce.bundle'),
    (Join-Path $env:ProgramData 'Autodesk\ApplicationPlugins\CutOnce.bundle')
)
foreach ($b in $bundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?)" }
    }
}

# A log folder on a network path or mapped drive, or one split into per-person
# subfolders, holds other people's logs too.
function Test-SharedFolder([string]$path, [string]$target) {
    if ($path.StartsWith('\\')) { return $true }
    if ([Environment]::GetEnvironmentVariable('CUTONCE_LOGSUBFOLDER', $target)) { return $true }
    try {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path)))
        return $drive.DriveType -eq [IO.DriveType]::Network
    } catch { return $true }
}

foreach ($target in 'User', 'Machine') {
    $instDir = [Environment]::GetEnvironmentVariable('CUTONCE_HOME', $target)
    if ($instDir -and (Test-Path (Join-Path $instDir 'CutOnce-Config.lsp'))) {
        foreach ($f in 'CutOnce-Loader.lsp', 'CutOnce-Config.lsp', 'CutOnce-Config.sample.lsp', 'CutOnce.vlx') {
            Remove-Item (Join-Path $instDir $f) -Force -ErrorAction SilentlyContinue
        }
        foreach ($d in 'src', 'Win64') { Remove-Item (Join-Path $instDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "Removed CutOnce files from $instDir"
        Write-Host '  If the LISP edition was loaded from acaddoc.lsp, delete its (load ...) line.'
    }
    $logs = [Environment]::GetEnvironmentVariable('CUTONCE_LOGDIR', $target)
    if ($RemoveLogs -and $logs -and (Test-SharedFolder $logs $target)) {
        Write-Host "Kept the shared log folder $logs (team and network folders are never deleted)."
    } elseif ($RemoveLogs -and $logs -and (Test-Path $logs)) {
        Remove-Item $logs -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $logs"
    }
    foreach ($name in 'CUTONCE_HOME', 'CUTONCE_LOGDIR', 'CUTONCE_LOGSUBFOLDER', 'CUTONCE_BACKUPDIR') {
        try { [Environment]::SetEnvironmentVariable($name, $null, $target) } catch { }
    }
}

# Registry "demand load" entries written by Install.ps1 -InstallDir
foreach ($hive in 'HKCU:\Software\Autodesk\AutoCAD', 'HKLM:\SOFTWARE\Autodesk\AutoCAD') {
    if (-not (Test-Path $hive)) { continue }
    Get-ChildItem $hive -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -eq 'CutOnce' -and $_.PSParentPath -like '*\Applications' } |
        ForEach-Object {
            try { Remove-Item $_.PSPath -Recurse -Force; Write-Host "Removed load entry $($_.Name)" }
            catch { Write-Warning "Could not remove $($_.Name) (administrator rights needed?)" }
        }
}

# Per-user choices (CutOnce.* values) live in each AutoCAD profile's FixedProfile\General key.
$acadKey = 'HKCU:\Software\Autodesk\AutoCAD'
if (Test-Path $acadKey) {
    Get-ChildItem $acadKey -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSPath -like '*\FixedProfile\General' } |
        ForEach-Object {
            $key = $_
            $key.GetValueNames() | Where-Object { $_ -like 'CutOnce.*' } | ForEach-Object {
                Remove-ItemProperty -Path $key.PSPath -Name $_ -ErrorAction SilentlyContinue
            }
        }
}

if ($RemoveLogs) {
    $default = Join-Path $env:LOCALAPPDATA 'CutOnce'
    if (Test-Path $default) { Remove-Item $default -Recurse -Force; Write-Host "Removed $default" }
}

Write-Host 'CutOnce removed.'
