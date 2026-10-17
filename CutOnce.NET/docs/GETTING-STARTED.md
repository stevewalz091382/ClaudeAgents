# Getting started: CutOnce .NET in VS Code

From an empty PC to a tested install zip your designers double-click. Allow about an hour the first time.

## 1. What you need

| Item | Why | Where |
|---|---|---|
| Windows 10 or 11, 64-bit | Civil 3D and WPF | |
| Civil 3D 2021–2024 **and/or** 2025+ installed on the build PC | The build references its `acmgd.dll`, `acdbmgd.dll` and `accoremgd.dll` | Your normal install |
| .NET 8 SDK (x64) | Builds both targets (it also builds .NET Framework 4.8) | <https://dotnet.microsoft.com/download/dotnet/8.0> |
| VS Code | Editor and debugger | <https://code.visualstudio.com> |
| C# Dev Kit extension | IntelliSense, build, debug | VS Code prompts for it when you open the folder |
| Internet access to nuget.org on the first build | The SDK downloads the .NET Framework 4.8 reference assemblies for the 2021–2024 build | Or install the ".NET Framework 4.8 Developer Pack" |

Which build serves which release:

| Civil 3D | AutoCAD series | Runtime | Build | Bundle folder |
|---|---|---|---|---|
| 2021, 2022, 2023, 2024 | R24.0 – R24.3 | .NET Framework 4.8 | `net48` | `Contents\Win64\R24` |
| 2025, 2026 and later | R25.x | .NET 8 | `net8.0-windows` | `Contents\Win64\R25` |

You only need the release(s) your firm uses. A package built with just one of them loads in that range only (the installer warns you).

## 2. Open the project

1. Copy the `CutOnce.NET` folder to your PC (or clone the repository).
2. In VS Code: **File > Open Folder...** and pick `CutOnce.NET`.
3. Accept **Install recommended extensions** (C# Dev Kit, C#, PowerShell, XML).
4. Wait for the Solution Explorer (bottom of the Explorer pane) to show **CutOnce.sln** with three projects:
   - `CutOnce.Core`: the logic that does not need AutoCAD.
   - `CutOnce.Civil3D`: the plugin.
   - `CutOnce.Core.Tests`: the tests.

## 3. Point the build at your Civil 3D

The defaults are `C:\Program Files\Autodesk\AutoCAD 2024` (for 2021–2024) and `C:\Program Files\Autodesk\AutoCAD 2025` (for 2025+). If yours differ (2026, another drive, only one release), edit the two lines at the top of `.vscode/tasks.json`:

```json
"CUTONCE_C3D_NET48": "C:\\Program Files\\Autodesk\\AutoCAD 2024",
"CUTONCE_C3D_NET8":  "C:\\Program Files\\Autodesk\\AutoCAD 2026"
```

A folder that does not exist is simply skipped. From a terminal the same thing is:

```powershell
dotnet build src\CutOnce.Civil3D -p:Civil3DDirNet8="C:\Program Files\Autodesk\AutoCAD 2026"
```

## 4. Build and test

| Do | How | Result |
|---|---|---|
| Build the plugin | **Ctrl+Shift+B** (task *Build plugin (Debug)*) | `src\CutOnce.Civil3D\bin\Debug\net48\CutOnce.Civil3D.dll` and/or `...\net8.0-windows\CutOnce.Civil3D.dll` |
| Run the logic tests | **Terminal > Run Task... > Run Core tests** | `25 passed, 0 failed` |

The tests cover the parts that do not need Civil 3D: reading `CutOnce-Config.lsp`, settings and locks, the CSV logs, growth rules, standards report, xref and coordinate checks, Learn More links and the dialog models. They run on any PC, so run them after every change.

## 5. Run it in Civil 3D

**Close Civil 3D first.** Windows locks a loaded plugin DLL until Civil 3D exits.

**Option A, the real install (recommended).** **Terminal > Run Task... > Build and install for debugging.** It builds Debug, packages the bundle with the `.pdb` files, and installs it to `%APPDATA%\Autodesk\ApplicationPlugins\CutOnce.bundle`. Start Civil 3D: CutOnce loads by itself, exactly as it will for designers.

**Option B, a quick NETLOAD.** In Civil 3D type `NETLOAD` and pick the DLL in `bin\Debug\<framework>`. Civil 3D asks whether to trust it the first time. CutOnce then reads `CutOnce-Config.lsp` from an installed bundle if there is one, or uses the built-in defaults. To use the repository's config, set a Windows environment variable `CUTONCE_HOME` to `...\CutOnce.NET\bundle\CutOnce.bundle\Contents`.

Check it loaded: the command line shows `[CutOnce] 2.2.0 loaded...`. Then type `CUTONCE-STATUS`.

## 6. Debug

`.vscode/launch.json` has three configurations (**Run and Debug** pane, or **F5**):

| Configuration | Use it for |
|---|---|
| *Civil 3D 2025+ (.NET 8): launch and debug* | Builds and installs (Option A), starts Civil 3D 2025 under the debugger. Change `program` and `cwd` for 2026 |
| *Civil 3D 2025+ (.NET 8): attach to running acad.exe* | Civil 3D already open: pick `acad.exe` |
| *Civil 3D 2021-2024 (.NET Framework 4.8): attach to running acad.exe* | Same, for the 4.8 build |

Good first breakpoints:

- `Modules/CommandGate.cs`, `OnLockModeChanged`: every command as it takes the drawing (this is where **Stop** vetoes).
- `Modules/ImpactService.cs`, `TransformPreStart` and `SelectionAdded`: MOVE / STRETCH / ROTATE / SCALE.
- `Modules/HealthService.cs`, `OnBeginSave`: every save.
- `Host/DocMonitor.cs`, `OnIdle`: the open-time check.

`CUTONCE-IMPACT-DEBUG` prints any error caught inside an event handler, instead of swallowing it.

## 7. Try every feature (acceptance checklist)

Use a test drawing with an alignment, a profile, a surface, a corridor, a block with attributes, a hatch and an xref.

| # | Do | Expect |
|---|---|---|
| 1 | Open a saved drawing with an xref moved off 0,0,0 | Standards dialog lists it; Events.csv `STANDARDS-OPEN` |
| 2 | Select the alignment, type `MOVE` | Impact warning before anything happens. **Stop MOVE**: nothing moves, `COMMAND-STOPPED` logged |
| 3 | Type `MOVE` with nothing selected, pick the alignment | Warning while selecting. **Leave them out**: the alignment drops out of the selection |
| 4 | Grip-edit the alignment | Impact warning with **Stop** |
| 5 | Select the alignment, type `EXPLODE` | Red "about to convert" warning with **Stop EXPLODE** |
| 6 | Type `EXPLODE`, then pick the attributed block | After it: warning with **Undo EXPLODE**; the block comes back |
| 7 | `BURST` several blocks | One warning for the whole BURST |
| 8 | Bind the xref (XREF palette > Bind) | Bind warning with **Undo**. Detaching an xref shows nothing |
| 9 | Type `TEXT` | Label-style tip with **Stop TEXT** |
| 10 | Add 30 layers, save twice | Growth warning: **Save a copy** puts a copy in the backup folder; **Clean up now...** opens cleanup after the save |
| 11 | Run cleanup | Result with counts; **Undo cleanup** reverses it all |
| 12 | `CUTONCE` | Control Center: switch the master Command warnings off and watch the rows grey out; Save; `CUTONCE-STATUS` |
| 13 | Lock a setting in the config, `CUTONCE-RELOADCONFIG`, `CUTONCE` | The row shows a lock and cannot be changed |
| 14 | Set `BrandColor` and `BrandLogo`, `CUTONCE-RELOADCONFIG`, `CUTONCE-PREVIEW` | The sample warning in your branding |
| 15 | Open the log folder (Control Center > Logging > Open) | Health.csv, Xrefs.csv, Events.csv, Opened.csv, Backups.csv |

Repeat 2, 5 and 6 in each Civil 3D release you ship for.

## 8. Make the install package

**Terminal > Run Task... > Package (Release zip)**, or:

```powershell
.\build\Build-Bundle.ps1
```

It builds Release for every release it finds, runs the tests, and writes:

```
dist\CutOnce-2.2.0\
    CutOnce.bundle\PackageContents.xml
    CutOnce.bundle\Contents\CutOnce-Config.lsp
    CutOnce.bundle\Contents\Win64\R24\CutOnce.Civil3D.dll     (Civil 3D 2021-2024)
    CutOnce.bundle\Contents\Win64\R25\CutOnce.Civil3D.dll     (Civil 3D 2025+)
    Install.cmd  Uninstall.cmd  Set-LogFolder.cmd  (+ .ps1)
    README.md  CAD-Admin-Guide.html
dist\CutOnce-2.2.0.zip
```

Only one release on your build PC? Build on a second PC for the other range and copy its `Win64\R24` or `Win64\R25` folder into the package before zipping, or ship two packages.

Before handing it out, set the firm's defaults, locks and branding in `bundle\CutOnce.bundle\Contents\CutOnce-Config.lsp` (it goes into every package).

## 9. Install for designers

Exactly as easy as the LISP edition:

1. Close Civil 3D.
2. Unzip, double-click **Install.cmd**.
3. Start Civil 3D, type `CUTONCE-STATUS`.

It installs to `%APPDATA%\Autodesk\ApplicationPlugins\CutOnce.bundle` (trusted, loads automatically), replaces the LISP edition in place, and keeps the existing `CutOnce-Config.lsp`, each designer's choices and all logs. All the install options are in the README (`-Scope AllUsers`, `-LogDir`, `-BackupDir`, `-InstallDir` for a network share).

## 10. If something goes wrong

| Problem | Fix |
|---|---|
| Build error "no AutoCAD / Civil 3D install found" | Set the folders in step 3 |
| Build error about `Microsoft.NETFramework.ReferenceAssemblies` | The PC cannot reach nuget.org: install the .NET Framework 4.8 Developer Pack, or build only `-f net8.0-windows` |
| `CUTONCE-STATUS` is an unknown command | The DLL did not load. Check the command line at startup for a CutOnce error; check `%APPDATA%\Autodesk\ApplicationPlugins\CutOnce.bundle\Contents\Win64\R24` or `R25` holds the DLL for your release; run `Install.cmd` again (it unblocks downloaded files) |
| "Could not load file or assembly" at startup | A net48 DLL in 2025+ or the reverse. The bundle picks by release; with NETLOAD, pick the right `bin` folder |
| A build fails with "file is being used by another process" | Civil 3D still has the DLL loaded: close it |
| A change to the code does nothing | .NET cannot unload a DLL: close Civil 3D, rebuild, reinstall, restart |
| A warning appears but Stop does nothing for one command | Tell us the command name (`CUTONCE-GUARD-LOGCOMMANDS`). Meanwhile `("StopOnLock" . nil)` in the config makes Stop send ESC at the command's first prompt instead |

## Where things are

| To change | Edit |
|---|---|
| Warning texts | `src/CutOnce.Core/Guard/GuardTexts.cs`, `Modules/ImpactService.cs`, `Modules/HealthService.cs` |
| Which commands can be stopped | `Modules/CommandGate.cs` (`IsGated`, `PreStart`) |
| Dialog look (colours, buttons, switches, frame) | `UI/Theme.xaml`, severity colours in `UI/BrandedWindow.cs` |
| Dialog layouts | `UI/NoticeWindow.xaml`, `UI/ControlCenterWindow.xaml`, `UI/CleanupWindow.xaml` |
| A new Control Center switch | Add it to `Core/Settings/SettingsCatalog.cs`; it appears in the dialog, `-CUTONCE` and the config automatically |
| Health.csv columns | `Core/Health/HealthSchema.cs` (changing columns archives the old log automatically) |
| Commands | `Commands/CutOnceCommands.cs` |
| Version number | `CutOnce.Civil3D.csproj` `<Version>`, `Core/Product.cs`, `PackageContents.xml` |
