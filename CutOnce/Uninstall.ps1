<#
.SYNOPSIS
    Removes CutOnce.

.DESCRIPTION
    Deletes the CutOnce.bundle from the user and (when elevated) all-users
    ApplicationPlugins folders, removes the custom install folder named by
    CUTONCE_HOME, and clears the CUTONCE_HOME / CUTONCE_LOGDIR variables.
    Logs (Health.csv, Xrefs.csv, Events.csv, Opened.csv) are kept unless
    -RemoveLogs is given. Each designer's Control Center choices are removed.
#>
[CmdletBinding()]
param([switch]$RemoveLogs)

$ErrorActionPreference = 'Stop'

if (Get-Process -Name acad -ErrorAction SilentlyContinue) {
    Write-Warning 'Civil 3D is running. Close it first so files are not in use.'
    Read-Host 'Press Enter when Civil 3D is closed (or Ctrl+C to stop)'
}

$bundles = @(
    (Join-Path $env:APPDATA      'Autodesk\ApplicationPlugins\CutOnce.bundle'),
    (Join-Path $env:ProgramData  'Autodesk\ApplicationPlugins\CutOnce.bundle')
)
foreach ($b in $bundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?)" }
    }
}

foreach ($target in 'User', 'Machine') {
    $instDir = [Environment]::GetEnvironmentVariable('CUTONCE_HOME', $target)
    if ($instDir -and (Test-Path (Join-Path $instDir 'CutOnce-Loader.lsp'))) {
        foreach ($f in 'CutOnce-Loader.lsp', 'CutOnce-Config.lsp', 'CutOnce-Config.sample.lsp', 'CutOnce.vlx') {
            Remove-Item (Join-Path $instDir $f) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item (Join-Path $instDir 'src') -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed CutOnce files from $instDir"
        Write-Host '  Remember to delete its (load ...) line from acaddoc.lsp.'
    }
    $logs = [Environment]::GetEnvironmentVariable('CUTONCE_LOGDIR', $target)
    if ($RemoveLogs -and $logs -and (Test-Path $logs)) {
        Remove-Item $logs -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $logs"
    }
    foreach ($name in 'CUTONCE_HOME', 'CUTONCE_LOGDIR') {
        try { [Environment]::SetEnvironmentVariable($name, $null, $target) } catch { }
    }
}

# Per-user preferences written by (setenv "CutOnce.*") live in each AutoCAD
# profile's FixedProfile\General key.
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
