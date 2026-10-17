<#
.SYNOPSIS
    Builds CutOnce and assembles the install package (CutOnce.bundle + installer).

.DESCRIPTION
    1. Finds your AutoCAD / Civil 3D installs (or uses the folders you pass).
    2. Builds the .NET Framework 4.8 DLL (Civil 3D 2021-2024) and the .NET 8 DLL
       (Civil 3D 2025+) - whichever you have an install for.
    3. Runs the CutOnce.Core tests.
    4. Lays out dist\CutOnce-<version>\ exactly like the LISP edition's release:
         CutOnce.bundle\PackageContents.xml
         CutOnce.bundle\Contents\CutOnce-Config.lsp
         CutOnce.bundle\Contents\Win64\R24\CutOnce.Civil3D.dll   (2021-2024)
         CutOnce.bundle\Contents\Win64\R25\CutOnce.Civil3D.dll   (2025+)
         Install.cmd / Uninstall.cmd / Set-LogFolder.cmd (+ .ps1), README, admin guide
    5. Zips it to dist\CutOnce-<version>.zip, ready to hand out.

.PARAMETER Configuration
    Release (default) or Debug. Debug also copies the .pdb files, for debugging.

.PARAMETER Civil3DDirNet48
    Install folder of Civil 3D 2021-2024, e.g. "C:\Program Files\Autodesk\AutoCAD 2024".

.PARAMETER Civil3DDirNet8
    Install folder of Civil 3D 2025 or later, e.g. "C:\Program Files\Autodesk\AutoCAD 2026".

.PARAMETER Install
    After building, install the bundle for the current user (runs Install.ps1).

.EXAMPLE
    .\build\Build-Bundle.ps1
.EXAMPLE
    .\build\Build-Bundle.ps1 -Configuration Debug -Install
.EXAMPLE
    .\build\Build-Bundle.ps1 -Civil3DDirNet8 "D:\Autodesk\AutoCAD 2026"
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string]$Civil3DDirNet48,
    [string]$Civil3DDirNet8,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'src\CutOnce.Civil3D\CutOnce.Civil3D.csproj'
$version = ([xml](Get-Content $project)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { $version = '0.0.0' }

# Newest install of a given AutoCAD year range that has the managed DLLs.
# Civil 3D installs (with a C3D folder) are preferred over plain AutoCAD.
function Find-Acad([int[]]$years) {
    $roots = @("$env:ProgramFiles\Autodesk")
    $found = foreach ($y in ($years | Sort-Object -Descending)) {
        foreach ($r in $roots) {
            $dir = Join-Path $r "AutoCAD $y"
            if (Test-Path (Join-Path $dir 'acdbmgd.dll')) {
                [pscustomobject]@{ Dir = $dir; Civil = Test-Path (Join-Path $dir 'C3D') }
            }
        }
    }
    ($found | Sort-Object -Property Civil -Descending | Select-Object -First 1).Dir
}

if (-not $Civil3DDirNet48) { $Civil3DDirNet48 = Find-Acad 2021..2024 }
if (-not $Civil3DDirNet8)  { $Civil3DDirNet8  = Find-Acad 2025..2030 }

$targets = @()
if ($Civil3DDirNet48) { $targets += [pscustomobject]@{ Tfm = 'net48';          Folder = 'R24'; Dir = $Civil3DDirNet48 } }
if ($Civil3DDirNet8)  { $targets += [pscustomobject]@{ Tfm = 'net8.0-windows'; Folder = 'R25'; Dir = $Civil3DDirNet8 } }
if (-not $targets) {
    throw 'No AutoCAD / Civil 3D 2021 or later found in Program Files\Autodesk. Pass -Civil3DDirNet48 or -Civil3DDirNet8.'
}

Write-Host "CutOnce $version - $Configuration build" -ForegroundColor Cyan
foreach ($t in $targets) { Write-Host ("  {0,-15} against {1}" -f $t.Tfm, $t.Dir) }

# ---- build -----------------------------------------------------------------
$buildArgs = @('build', $project, '-c', $Configuration, '-nologo')
if ($Civil3DDirNet48) { $buildArgs += "-p:Civil3DDirNet48=$Civil3DDirNet48" }
if ($Civil3DDirNet8)  { $buildArgs += "-p:Civil3DDirNet8=$Civil3DDirNet8" }
& dotnet @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

# ---- tests -------------------------------------------------------------------
& dotnet run --project (Join-Path $root 'tests\CutOnce.Core.Tests') -c $Configuration --nologo
if ($LASTEXITCODE -ne 0) { throw 'CutOnce.Core tests failed.' }

# ---- lay out the package -------------------------------------------------------
$dist    = Join-Path $root 'dist'
$pkg     = Join-Path $dist "CutOnce-$version"
$bundle  = Join-Path $pkg 'CutOnce.bundle'
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'Contents') | Out-Null

Copy-Item (Join-Path $root 'bundle\CutOnce.bundle\PackageContents.xml') $bundle
Copy-Item (Join-Path $root 'bundle\CutOnce.bundle\Contents\*') (Join-Path $bundle 'Contents') -Recurse

foreach ($t in $targets) {
    $out = Join-Path $root "src\CutOnce.Civil3D\bin\$Configuration\$($t.Tfm)"
    $dest = Join-Path $bundle "Contents\Win64\$($t.Folder)"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $out 'CutOnce.Civil3D.dll') $dest
    if ($Configuration -eq 'Debug') { Copy-Item (Join-Path $out 'CutOnce.Civil3D.pdb') $dest -ErrorAction SilentlyContinue }
}
foreach ($f in 'Install.ps1', 'Install.cmd', 'Uninstall.ps1', 'Uninstall.cmd', 'Set-LogFolder.ps1', 'Set-LogFolder.cmd') {
    Copy-Item (Join-Path $root "build\installer\$f") $pkg
}
Copy-Item (Join-Path $root 'README.md') $pkg
Copy-Item (Join-Path $root 'docs\CAD-Admin-Guide.html') $pkg

$missing = @('R24', 'R25') | Where-Object { -not (Test-Path (Join-Path $bundle "Contents\Win64\$_\CutOnce.Civil3D.dll")) }
foreach ($m in $missing) {
    $range = if ($m -eq 'R24') { 'Civil 3D 2021-2024' } else { 'Civil 3D 2025 and later' }
    Write-Warning "No $m build: this package will not load in $range. Build on a PC with that release installed (or pass its folder) to include it."
}

$zip = Join-Path $dist "CutOnce-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip
Write-Host ''
Write-Host "Package: $pkg" -ForegroundColor Green
Write-Host "Zip:     $zip" -ForegroundColor Green

if ($Install) {
    & (Join-Path $pkg 'Install.ps1')
}
