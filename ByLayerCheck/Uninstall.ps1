<#
.SYNOPSIS
    Removes ByLayerCheck.

.DESCRIPTION
    Deletes ByLayerCheck.bundle from the user and (when elevated) all-users
    ApplicationPlugins folders, removes the files from the custom install
    folder named by BYLAYERCHECK_HOME, and clears that variable.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (Get-Process -Name acad -ErrorAction SilentlyContinue) {
    Write-Warning 'Civil 3D is running. Close it first so files are not in use.'
    Read-Host 'Press Enter when Civil 3D is closed (or Ctrl+C to stop)'
}

$bundles = @(
    (Join-Path $env:APPDATA     'Autodesk\ApplicationPlugins\ByLayerCheck.bundle'),
    (Join-Path $env:ProgramData 'Autodesk\ApplicationPlugins\ByLayerCheck.bundle')
)
foreach ($b in $bundles) {
    if (Test-Path $b) {
        try { Remove-Item $b -Recurse -Force; Write-Host "Removed $b" }
        catch { Write-Warning "Could not remove $b (administrator rights needed?)" }
    }
}

foreach ($target in 'User', 'Machine') {
    $instDir = [Environment]::GetEnvironmentVariable('BYLAYERCHECK_HOME', $target)
    if ($instDir -and (Test-Path (Join-Path $instDir 'ByLayerCheck-Loader.lsp'))) {
        foreach ($f in 'ByLayerCheck-Loader.lsp', 'ByLayerCheck-Config.lsp', 'ByLayerCheck.vlx') {
            Remove-Item (Join-Path $instDir $f) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item (Join-Path $instDir 'src') -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed ByLayerCheck files from $instDir"
        Write-Host '  Remember to delete its (load ...) line from acaddoc.lsp.'
    }
    try { [Environment]::SetEnvironmentVariable('BYLAYERCHECK_HOME', $null, $target) } catch { }
}

Write-Host 'ByLayerCheck removed.'
