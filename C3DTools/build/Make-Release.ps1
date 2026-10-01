<#
.SYNOPSIS
    Packages C3DTools for hand-off: dist\C3DTools-<version>.zip

.DESCRIPTION
    Refuses to package unless C3DTools.vlx has been built (see BUILD.md) and
    the static checks pass. The zip contains the bundle (loader, config, VLX
    and manifest), the install/uninstall scripts and README.md. The .lsp
    sources are NOT included.

    -SourceBuild packages the .lsp sources instead of a VLX, for testing
    before the VLX is compiled. Its Install.cmd passes -AllowSource. The
    sources are readable by anyone who receives the zip.
#>
param([switch]$SourceBuild)
$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$contents = Join-Path $root 'C3DTools.bundle\Contents'
$vlx      = Join-Path $contents 'C3DTools.vlx'

if (-not $SourceBuild -and -not (Test-Path $vlx)) { throw "Build C3DTools.vlx first (BUILD.md), or use -SourceBuild. Expected at $vlx" }

$python = Get-Command python, python3, py -ErrorAction SilentlyContinue | Select-Object -First 1
if ($python) {
    & $python.Source (Join-Path $root 'tools\check_lisp.py')
    if ($LASTEXITCODE -ne 0) { throw 'Static checks failed.' }
} else {
    Write-Warning 'Python not found - skipping tools\check_lisp.py.'
}

$manifest = [xml](Get-Content (Join-Path $root 'C3DTools.bundle\PackageContents.xml'))
$version  = $manifest.ApplicationPackage.AppVersion
if (-not $manifest.ApplicationPackage.Author) {
    Write-Warning 'PackageContents.xml has no publisher (Author) set.'
}

$suffix = if ($SourceBuild) { '-source' } else { '' }
$stage = Join-Path $root "dist\C3DTools-$version$suffix"
$zip   = "$stage.zip"
Remove-Item $stage, $zip -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'C3DTools.bundle\Contents') | Out-Null

Copy-Item (Join-Path $root 'C3DTools.bundle\PackageContents.xml') (Join-Path $stage 'C3DTools.bundle')
$bundleFiles = @('C3DTools-Loader.lsp', 'C3DTools-Config.lsp')
if (-not $SourceBuild) { $bundleFiles += 'C3DTools.vlx' }
foreach ($f in $bundleFiles) {
    Copy-Item (Join-Path $contents $f) (Join-Path $stage 'C3DTools.bundle\Contents')
}
foreach ($f in 'Install.cmd', 'Install.ps1', 'Uninstall.cmd', 'Uninstall.ps1', 'README.md') {
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
