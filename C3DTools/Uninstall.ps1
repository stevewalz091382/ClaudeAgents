<#
.SYNOPSIS
    Removes C3DTools.

.DESCRIPTION
    Deletes the C3DTools.bundle from the user and (when elevated) all-users
    ApplicationPlugins folders, removes the custom install folder named by
    C3DTOOLS_HOME, and clears the C3DTOOLS_HOME / C3DTOOLS_LOGDIR variables.
    Logs and reports are kept unless -RemoveLogs is given.

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
    (Join-Path $env:APPDATA      'Autodesk\ApplicationPlugins\C3DTools.bundle'),
    (Join-Path $env:ProgramData  'Autodesk\ApplicationPlugins\C3DTools.bundle')
)
foreach ($b in $bundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?)" }
    }
}

foreach ($target in 'User', 'Machine') {
    $instDir = [Environment]::GetEnvironmentVariable('C3DTOOLS_HOME', $target)
    if ($instDir -and (Test-Path (Join-Path $instDir 'C3DTools-Loader.lsp'))) {
        foreach ($f in 'C3DTools-Loader.lsp', 'C3DTools-Config.lsp', 'C3DTools.vlx') {
            Remove-Item (Join-Path $instDir $f) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item (Join-Path $instDir 'src') -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed C3DTools files from $instDir"
        Write-Host '  Remember to delete its (load ...) line from acaddoc.lsp.'
    }
    $logs = [Environment]::GetEnvironmentVariable('C3DTOOLS_LOGDIR', $target)
    if ($RemoveLogs -and $logs -and (Test-Path $logs)) {
        Remove-Item $logs -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $logs"
    }
    foreach ($name in 'C3DTOOLS_HOME', 'C3DTOOLS_LOGDIR') {
        try { [Environment]::SetEnvironmentVariable($name, $null, $target) } catch { }
    }
}

# Per-user preferences written by (setenv "C3DTools.*") live in each AutoCAD
# profile's FixedProfile\General key.
$acadKey = 'HKCU:\Software\Autodesk\AutoCAD'
if (Test-Path $acadKey) {
    Get-ChildItem $acadKey -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSPath -like '*\FixedProfile\General' } |
        ForEach-Object {
            $key = $_
            $key.GetValueNames() | Where-Object { $_ -like 'C3DTools.*' } | ForEach-Object {
                Remove-ItemProperty -Path $key.PSPath -Name $_ -ErrorAction SilentlyContinue
            }
        }
}

if ($RemoveLogs) {
    $default = Join-Path $env:LOCALAPPDATA 'C3DTools'
    if (Test-Path $default) { Remove-Item $default -Recurse -Force; Write-Host "Removed $default" }
}

Write-Host 'C3DTools removed.'
