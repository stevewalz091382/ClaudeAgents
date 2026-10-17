# How CutOnce went from AutoLISP to a .NET plugin

This guide explains how CutOnce 2.1 (seven AutoLISP files, about 4,900 lines, packaged as a VLX bundle) became CutOnce 2.2, a C# plugin with WPF dialogs, and why each choice was made. Use it to maintain the code, or as a recipe for converting other LISP tools.

## The steps, in order

1. **Inventory the LISP.** List every `c:` command, every reactor, every `setenv` / `getenv` value, every file it writes and every DCL dialog. These are the contract designers and admins rely on; the port keeps all of them. For CutOnce: 22 commands, command / LISP / editor reactors, about 35 profile values, 5 CSV logs, 4 dialogs.
2. **Split pure logic from AutoCAD calls.** Rules such as "flag growth of 20% or more", CSV quoting, the config format and the standards report do not need AutoCAD. They went into `CutOnce.Core`, which builds and is unit-tested anywhere. Everything that touches a drawing went into `CutOnce.Civil3D`.
3. **Keep the admin's files working.** `CutOnce-Config.lsp` is AutoLISP *data*. Rather than make every firm rewrite it as JSON, `Core/Config/LispReader.cs` reads it (lists, dotted pairs, quote, strings, numbers, T, nil, comments) without running it. Designer choices stay in the same AutoCAD profile values (`CutOnce.WarnMOVE` = `"0"` / `"1"`), so nothing is lost on upgrade.
4. **Port each module, keeping names and messages.** One LISP file became one or more C# classes (table below). Command names, warning texts, Learn More topics, log columns and event codes are the same, so documentation, toolbar macros and Excel reports keep working.
5. **Replace reactors with events.** See the mapping table.
6. **Replace DCL with WPF.** DCL cannot set fonts, colours or layout freely; WPF can. All four dialogs share one branded frame (`UI/BrandedWindow.cs` + `UI/Theme.xaml`) and are driven by models from Core, so the modules never touch UI code.
7. **Add what LISP could not do.** Stopping a command (below).
8. **Package as a bundle.** The same `CutOnce.bundle` folder and the same installer experience; `PackageContents.xml` now points at a DLL per release range instead of a loader `.lsp`.
9. **Test.** Core logic with the test project; the plugin by the acceptance checklist in [GETTING-STARTED.md](GETTING-STARTED.md).

## LISP to .NET, side by side

| AutoLISP | .NET in this project | Notes |
|---|---|---|
| `(defun c:CUTONCE ...)` | `[CommandMethod("CUTONCE", "CUTONCE", CommandFlags.Modal)]` in `Commands/CutOnceCommands.cs` | Same names, including `-CUTONCE` |
| `vlr-command-reactor` `:vlr-commandWillStart / Ended / Cancelled / Failed` | `Document.CommandWillStart / CommandEnded / CommandCancelled / CommandFailed` (`Host/DocMonitor.cs`) | Attached to every drawing as it opens |
| `vlr-lisp-reactor` | `Document.LispWillStart / LispEnded / LispCancelled` | Batches BURST's many EXPLODEs into one warning |
| `vlr-editor-reactor :vlr-beginSave` | `Database.BeginSave` | Autosave (`.sv$`) is now skipped |
| Loader runs per drawing at open | `DocumentCollection.DocumentCreated` + `Application.Idle` | The open-time check waits until the drawing is idle |
| `(ssget "_I")` / `(ssget "_P")` | `Editor.SelectImplied()` / `Editor.SelectPrevious()` | Plus `Document.ImpliedSelectionChanged` as a cache |
| `vlax-for` over Model Space, `vla-get-*` | `Transaction` + `BlockTableRecord` enumeration; `ObjectId.ObjectClass.Name` for type counts without opening objects | One read-only transaction per scan |
| `entget` DXF 62 / 6 for ByLayer | `Entity.Color.IsByLayer`, `Entity.Linetype` | Same rules: ByBlock and true colour count as not ByLayer |
| Civil 3D COM (`AeccXUiLand.AeccApplication.13.x`, `CUTONCE-FINDCIVIL`) | Civil 3D .NET API by reflection (`Host/Civil.cs`, `Host/SafeProps.cs`) | No ProgID hunt, no `AeccDbMgd` compile reference: one source tree for every release |
| `(setenv "CutOnce.X" "1")` / `getenv` | Registry `HKCU\<product key>\FixedProfile\General` (`Host/RegistryPreferenceStore.cs`) | The very same values |
| `vl-bb-set` blackboard (warned once per session) | A static set shared by all drawings (`CutOnceApp`) | |
| `(command "_.-PURGE" ...)` | `Editor.Command("_.-PURGE", ...)` | Synchronous, inside a modal command |
| `vla-SendCommand` (queue cleanup after save) | `Document.SendStringToExecute` | |
| DCL written to a temp file, `new_dialog`, `action_tile` | WPF windows shown with `Application.ShowModalWindow` | Owned by Civil 3D's main window, centred on it |
| `vector_image` / `slide_image` logo | WPF vector mark / PNG logo | `BrandLogo` replaces `BrandLogoSlide` |
| `alert` fallback | `Application.ShowAlertDialog` fallback | Used only if a WPF window cannot be shown |
| `vl-file-copy`, `open` / `write-line` | `File.Copy`, `StreamWriter` | Logs written UTF-8; a log open in Excel is skipped, as before |
| `startapp "explorer"`, `Shell.Application` | `Process.Start` | |
| VLX + `CutOnce-Loader.lsp` in the bundle | `CutOnce.Civil3D.dll` per release range in the bundle | `LoadOnAutoCADStartup="True"` |

## File map

| LISP file | .NET files |
|---|---|
| `CutOnce-Core.lsp` | `Core/Config/*`, `Core/Settings/*`, `Core/Logging/*`, `Core/Text/*`, `Core/Notices/NoticeRequest.cs`, `Host/*`, `Modules/Notices.cs`, `Modules/BackupService.cs`, `UI/*` |
| `CutOnce-Standards.lsp` | `Core/Standards/*`, `Scanning/DrawingScanner.cs`, `Modules/StandardsService.cs` |
| `CutOnce-Health.lsp` | `Core/Health/*`, `Modules/HealthService.cs` |
| `CutOnce-Guard.lsp` | `Core/Guard/*`, `Scanning/ObjectCounter.cs`, `Modules/GuardService.cs` |
| `CutOnce-Impact.lsp` | `Modules/ImpactAnalyzer.cs`, `Modules/ImpactService.cs` |
| `CutOnce-Cleanup.lsp` | `Core/Cleanup/CleanupPlan.cs`, `Modules/CleanupService.cs` |
| `CutOnce-ControlCenter.lsp` | `Core/ViewModels/ControlCenterViewModel.cs`, `Modules/ControlCenter.cs`, `UI/ControlCenterWindow.xaml` |
| `CutOnce-Loader.lsp` | `Plugin.cs`, `CutOnceApp.cs` (finds the install folder and config) |
| new | `Modules/CommandGate.cs` (stopping commands) |

## How "Stop" works

AutoLISP reactors are notified *after* a command has been accepted; nothing in them can cancel it. That is why the LISP edition said "click OK, then press ESC".

.NET has three better moments, and CutOnce uses all three:

1. **Before the command runs.** When a command starts, Civil 3D locks the drawing for it and raises `DocumentCollection.DocumentLockModeChanged` with the command's name, before the command does anything. The handler can call `e.Veto()`, and the command is cancelled outright. `CommandGate.OnLockModeChanged` shows the warning there; **Stop** vetoes. (A second event for the same command arrives with a `#` prefix when the lock is released; it is ignored.)
2. **While objects are being picked.** For MOVE, STRETCH, ROTATE and SCALE started with nothing selected, `Editor.SelectionAdded` reports each pick before the command uses it. `ImpactService.SelectionAdded` warns as soon as a Civil 3D object with dependents is picked: **Leave them out** removes them from the selection (`e.Remove(i)`), **Stop** empties the selection and cancels the command.
3. **After the command.** Where the damage can only be measured afterwards (an EXPLODE inside BURST, an xref bind from the palette), the warning offers **Undo**, which queues `U`.

Safety rails:

- Each command's pre-start warning is shown exactly once, whichever order Civil 3D raises `CommandWillStart` and the lock event in. If no lock event arrives, the warning shows from `Application.Idle` while the command waits for input, and Stop sends ESC.
- `("StopOnLock" . nil)` in the config turns off warnings in the lock event entirely (LISP-edition timing, Stop sends ESC), in case a command ever misbehaves.
- Enter, ESC and the close button all mean **Continue**: nobody stops a command by accident.

## Why reflection for Civil 3D

Compiling against `AeccDbMgd.dll` ties a build to one Civil 3D release's API and forces the build PC to have Civil 3D. CutOnce reads a handful of members (`GetAlignmentIds`, `GetProfileIds`, `Baselines`, `AlignmentId`, `ProfileId`, `Name`, the style collections, the coordinate system code), so it reaches them by name, fail-safe, the way the LISP edition's `cutonce:prop` did. A member that a release lacks returns nothing instead of crashing, and the build only needs the three AutoCAD DLLs.

## Behaviour that changed on purpose

| Area | LISP edition | .NET edition |
|---|---|---|
| Stopping | Click OK, press ESC | Stop / Undo / Leave them out buttons |
| EXPLODE with objects selected first | Warned after | Warned before, with Stop |
| Xref detached | Reported as bound | Not reported (nothing is lost) |
| Health.csv Open rows | Styles and settings `n/a` | Filled in |
| `Styles`, `AngularUnits` columns | From COM | From the .NET API (Styles counted from the style collections; AngularUnits as a name) |
| Config changes | Restart | `CUTONCE-RELOADCONFIG` |
| Logo | AutoCAD slide (`.sld`) | PNG / JPG (`BrandLogo`) |
| Brand colour | ACI number | `"#RRGGBB"` or ACI number |
| Autosave | Ran the save check | Skipped |

Everything else is meant to behave exactly as before. If you find a difference that is not in this table, it is a bug.
