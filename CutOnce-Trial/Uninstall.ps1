# Copyright (c) 2026 Stephen Walz. All rights reserved.
<#
.SYNOPSIS
    Removes the CutOnce Trial.

.DESCRIPTION
    Deletes the CutOnce.bundle from the user and (when elevated) all-users
    ApplicationPlugins folders, removes the custom install folder named by
    CUTONCE_HOME, and clears the CUTONCE_HOME variable. Each designer's
    Control Center choices are removed.
#>
[CmdletBinding()]
param()

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
    try { [Environment]::SetEnvironmentVariable('CUTONCE_HOME', $null, $target) } catch { }
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

Write-Host 'CutOnce removed.'
