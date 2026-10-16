# CutOnceLabels (optional .NET helper)

Lets CutOnce detect Civil 3D labels whose text has been typed over. AutoLISP
cannot see this (labels expose no override property to `getpropertyvalue` or
COM), but the Civil 3D .NET API can (`Label.IsTextComponentOverriden`). Without
this DLL, typed-over labels are reported as "could not be checked".

## Build (once per .NET generation)

Needs the .NET SDK 8 (free, `winget install Microsoft.DotNet.SDK.8`) on a PC
with Civil 3D installed. The AutoCAD assemblies are referenced from the Civil 3D
install folder, which is the AutoCAD folder (e.g. `C:\Program Files\Autodesk\AutoCAD 2024`).

| Civil 3D | Command (run in this folder) | Copy the DLL to |
|---|---|---|
| 2021 - 2024 | `dotnet build -c Release -p:AcadDir="C:\Program Files\Autodesk\AutoCAD 2024"` | `CutOnce.bundle\Contents\net48\CutOnceLabels.dll` |
| 2025 and later | `dotnet build -c Release -p:AcadDir="C:\Program Files\Autodesk\AutoCAD 2025" -p:TargetFramework=net8.0-windows` | `CutOnce.bundle\Contents\net8\CutOnceLabels.dll` |

The build output is in `bin\Release\net48\` or `bin\Release\net8.0-windows\`.
Copy it into the install package, then run `Install.cmd` as usual.
`PackageContents.xml` makes Civil 3D load the right one for its release; the
installer drops the entry for any DLL you did not build.

## Check it

In Civil 3D, type `CUTONCE-LABEL-PROBE` and pick a typed-over label. The
"NET helper" line should say it is loaded and report `typed over: 1` (or more),
and `0` on an unchanged label.

The helper only reads labels; it never changes a drawing.
