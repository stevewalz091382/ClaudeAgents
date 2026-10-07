<#
.SYNOPSIS
    Removes CutOnce.

.DESCRIPTION
    Deletes the CutOnce.bundle from the user and (when elevated) all-users
    ApplicationPlugins folders, removes the custom install folder named by
    CUTONCE_HOME, and clears the CUTONCE_HOME / CUTONCE_LOGDIR variables.
    Logs (Health.csv, Xrefs.csv, Events.csv, Opened.csv) are kept unless
    -RemoveLogs is given. Each designer's Control Center choices are removed.

    MOVE/STRETCH/ROTATE/SCALE need no clean-up: UNDEFINE only lasts for the
    Civil 3D session.
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
    (Join-Path $env:ProgramData  'Autodesk\ApplicationPlugins\CutOnce.bundle'),
    # pre-rename installs
    (Join-Path $env:APPDATA      'Autodesk\ApplicationPlugins\ModelWise.bundle'),
    (Join-Path $env:ProgramData  'Autodesk\ApplicationPlugins\ModelWise.bundle')
)
foreach ($b in $bundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?)" }
    }
}

foreach ($target in 'User', 'Machine') {
    foreach ($pair in @(@('CUTONCE_HOME', 'CutOnce'), @('MODELWISE_HOME', 'ModelWise'))) {
    $instDir = [Environment]::GetEnvironmentVariable($pair[0], $target)
    $n = $pair[1]
    if ($instDir -and (Test-Path (Join-Path $instDir "$n-Loader.lsp"))) {
        foreach ($f in "$n-Loader.lsp", "$n-Config.lsp", "$n-Config.sample.lsp", "$n.vlx") {
            Remove-Item (Join-Path $instDir $f) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item (Join-Path $instDir 'src') -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $n files from $instDir"
        Write-Host '  Remember to delete its (load ...) line from acaddoc.lsp.'
    }
    }
    foreach ($logVar in 'CUTONCE_LOGDIR', 'MODELWISE_LOGDIR') {
        $logs = [Environment]::GetEnvironmentVariable($logVar, $target)
        if ($RemoveLogs -and $logs -and (Test-Path $logs)) {
            Remove-Item $logs -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Removed $logs"
        }
    }
    foreach ($name in 'CUTONCE_HOME', 'CUTONCE_LOGDIR', 'MODELWISE_HOME', 'MODELWISE_LOGDIR') {
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
            # ModelWise.* and C3DTools.* entries are choices carried over from
            # earlier versions; remove them too.
            $key.GetValueNames() | Where-Object { $_ -like 'CutOnce.*' -or $_ -like 'ModelWise.*' -or $_ -like 'C3DTools.*' } | ForEach-Object {
                Remove-ItemProperty -Path $key.PSPath -Name $_ -ErrorAction SilentlyContinue
            }
        }
}

if ($RemoveLogs) {
    foreach ($folder in 'CutOnce', 'ModelWise') {
        $default = Join-Path $env:LOCALAPPDATA $folder
        if (Test-Path $default) { Remove-Item $default -Recurse -Force; Write-Host "Removed $default" }
    }
}

Write-Host 'CutOnce removed.'
