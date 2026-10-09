<#
.SYNOPSIS
    Packages CutOnce for hand-off: dist\CutOnce-<version>.zip

.DESCRIPTION
    Refuses to package unless CutOnce.vlx has been built (see BUILD.md) and
    the static checks pass. The zip contains the bundle (loader, config, VLX
    and manifest), the install/uninstall/log-folder scripts, README.md and
    CAD-Admin-Guide.html. The .lsp
    sources are NOT included.

    -SourceBuild packages the .lsp sources instead of a VLX, for testing
    before the VLX is compiled. Its Install.cmd passes -AllowSource. The
    sources are readable by anyone who receives the zip.
#>
param([switch]$SourceBuild)
$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$contents = Join-Path $root 'CutOnce.bundle\Contents'
$vlx      = Join-Path $contents 'CutOnce.vlx'

if (-not $SourceBuild -and -not (Test-Path $vlx)) { throw "Build CutOnce.vlx first (BUILD.md), or use -SourceBuild. Expected at $vlx" }

$python = Get-Command python, python3, py -ErrorAction SilentlyContinue | Select-Object -First 1
if ($python) {
    & $python.Source (Join-Path $root 'tools\check_lisp.py')
    if ($LASTEXITCODE -ne 0) { throw 'Static checks failed.' }
} else {
    Write-Warning 'Python not found - skipping tools\check_lisp.py.'
}

$manifest = [xml](Get-Content (Join-Path $root 'CutOnce.bundle\PackageContents.xml'))
$version  = $manifest.ApplicationPackage.AppVersion
if (-not $manifest.ApplicationPackage.Author) {
    Write-Warning 'PackageContents.xml has no publisher (Author) set.'
}

$suffix = if ($SourceBuild) { '-source' } else { '' }
$stage = Join-Path $root "dist\CutOnce-$version$suffix"
$zip   = "$stage.zip"
Remove-Item $stage, $zip -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'CutOnce.bundle\Contents') | Out-Null

Copy-Item (Join-Path $root 'CutOnce.bundle\PackageContents.xml') (Join-Path $stage 'CutOnce.bundle')
$bundleFiles = @('CutOnce-Loader.lsp', 'CutOnce-Config.lsp')
if (-not $SourceBuild) { $bundleFiles += 'CutOnce.vlx' }
foreach ($f in $bundleFiles) {
    Copy-Item (Join-Path $contents $f) (Join-Path $stage 'CutOnce.bundle\Contents')
}
foreach ($f in 'Install.cmd', 'Install.ps1', 'Uninstall.cmd', 'Uninstall.ps1', 'Set-LogFolder.cmd', 'Set-LogFolder.ps1', 'README.md', 'CAD-Admin-Guide.html') {
    Copy-Item (Join-Path $root $f) $stage
}
if ($SourceBuild) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'src') | Out-Null
    Copy-Item (Join-Path $root 'src\*.lsp') (Join-Path $stage 'src')
    $cmd = Join-Path $stage 'Install.cmd'
    (Get-Content $cmd) -replace '%\*', '-AllowSource %*' | Set-Content $cmd
}

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Created $zip"
