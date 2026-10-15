# CutOnce 2.1 for Civil 3D

Publisher: Stephen Walz

CutOnce keeps Civil 3D models healthy while designers work. It does three things:

- **Guard.** Catches data-loss moves (EXPLODE, xref binds, moved xrefs) and shows what an edit will break before it happens.
- **Learn.** Every warning explains why it matters and links to a knowledge-base article for that exact situation.
- **Insights.** Logs model health on every open and save, so teams can see trends across drawings, projects and people.

**New in 2.1:** one-click bloat cleanup offered by the growth check, a **Save a copy** button on every warning (and before cleanup) that copies the drawing to a shared backup folder, typed-over Civil 3D label counts (open-time check, Health.csv, Labels.csv), and a coordinate system and units guard (open and save).

CutOnce is one AutoLISP package that loads into every drawing. Each designer decides what runs for them in the **CutOnce Control Center**.

| Part | What it does | Interrupts the user? |
|---|---|---|
| **Standards check** | When a drawing opens: objects not ByLayer, xrefs broken or unloaded, xrefs not at 0,0,0, Civil 3D labels with typed-over text, coordinate system and insertion units | Only when something is wrong (or always, if the designer chooses) |
| **Health log** | Writes a Health.csv row (and Xrefs.csv and Labels.csv detail) on every save and open: counts, styles, ByLayer, xrefs, typed-over labels, drawing settings, coordinate system | Never |
| **Guard** | Warns when EXPLODE (of Civil 3D objects, blocks or hatches), BURST, XREF bind, or moving an xref destroys data. Flags unusual growth, xrefs off 0,0,0 and coordinate system / units problems on save | Only when something risky happens |
| **Cleanup** | When the growth check fires, offers one-click cleanup of unused registered apps, scales, styles and anonymous blocks (PURGE, AUDIT), after saving a backup copy to a shared folder | Only when the designer clicks Clean up now... |
| **Impact** | Before an alignment, surface or profile is edited, lists what depends on it | On grip edits, surface edits and MOVE/STRETCH/ROTATE/SCALE of those objects |
| **CutOnce Control Center** | One dialog to switch every item above on or off, per designer, including logging | Only when opened |

## CutOnce Control Center

Type `CUTONCE`.

| Group | Switches |
|---|---|
| Command warnings | Master on/off, every time or once per command per session, then one row per command (below) |
| Checks on save | Unusual growth, offer cleanup when growth is flagged, xref not at 0,0,0, coordinate system / units, backup copy before cleanup; **Open backup folder** |
| Standards check on open | Run on open, ByLayer, xref status (broken/unloaded), xref not at 0,0,0, typed-over labels, coordinate system / units, always show result, include block definitions |
| Logging | Master on/off, then Health.csv on save, Health.csv on open, Xrefs.csv, Events.csv, Opened.csv, Labels.csv |

- Choices are stored in the designer's AutoCAD profile and apply to every open drawing immediately.
- Turning a master switch off greys out the items under it.
- **Reset to defaults** returns to the firm's defaults from `CutOnce-Config.lsp`.
- **Open log folder** opens the folder the logs are written to.
- Items the CAD administrator has locked are greyed out and say so.

### Command warnings

Every command CutOnce watches has its own tick box, switching that command's warning on or off.

| Row | Warns about | When |
|---|---|---|
| MOVE | Civil 3D objects with dependents, and xrefs | Civil 3D objects: at the start if pre-selected, otherwise after (type U). Xrefs: after |
| COPY | Xrefs copied off their insertion point | After the command (type U) |
| STRETCH, ROTATE, SCALE | Civil 3D objects with dependents | At the start if pre-selected, otherwise after (type U) |
| EXPLODE | EXPLODE / BURST of Civil 3D objects, blocks, hatches, attributed blocks | After the command (type U) |
| XREF / XBIND bind | Binding an xref into the drawing | After the command |
| REFEDIT | REFEDIT / REFCLOSE advisory | At the start |
| Promote reference | Promoting a data shortcut reference (any command whose name contains PROMOTE) | At the start |
| TEXT, DTEXT, MTEXT | Label style tip | At the start |
| Grip edits | Alignments, profiles and surfaces | At the start |
| Surface edits | Surface-edit commands | At the start |
| Other watched commands (added by CAD admin) | Commands in `ImpactExtraCommands` | At the start |

The **How to add other watched commands...** button under the list opens step-by-step instructions for the CAD administrator (find the command name with `CUTONCE-GUARD-LOGCOMMANDS`, add it to `ImpactExtraCommands` in `CutOnce-Config.lsp`, restart). It also shows the config file's location and the commands currently added.

**Frequency.** *Every time* or *Once per command per session* applies to every command warning above and to the save checks (growth and xref origin, once per drawing). A suppressed warning is still written to `Events.csv`. `CUTONCE-CHECK` and `CUTONCE-GUARD-CHECKNOW` always show their result.

Command-line version, for scripts and toolbar buttons: `-CUTONCE`. Type a setting name (or enough of it to be unique) to toggle it, or `List`, `Frequency`, `Warnings` (master switch), `Defaults`, `eXit`.

| Button macro | Effect |
|---|---|
| `^C^C-CUTONCE;LogEnabled;;` | Toggle all logging |
| `^C^C-CUTONCE;StdCheckOnOpen;;` | Toggle the standards check on open |
| `^C^C-CUTONCE;WarnEXPLODE;;` | Toggle the EXPLODE warning |

Setting names: `CommandWarnings`, `WarnMOVE`, `WarnCOPY`, `WarnSTRETCH`, `WarnROTATE`, `WarnSCALE`, `WarnEXPLODE`, `WarnXREFBIND`, `WarnREFEDIT`, `WarnPROMOTE`, `WarnTEXT`, `WarnDTEXT`, `WarnMTEXT`, `WarnGRIPS`, `WarnSURFACE`, `WarnOTHER`, `GuardGrowth`, `GuardCleanup`, `GuardXrefOrigin`, `GuardCoordUnits`, `BackupBeforeCleanup`, `StdCheckOnOpen`, `StdByLayer`, `StdXrefStatus`, `StdXrefOrigin`, `StdLabelOverrides`, `StdCoordUnits`, `StdAlwaysShow`, `StdScanBlocks`, `LogEnabled`, `LogHealthOnSave`, `LogHealthOnOpen`, `LogXrefs`, `LogEvents`, `LogOpened`, `LogLabels`.

## Logs

All files go to the log folder (see `CUTONCE-STATUS`), none to the drawing's folder. CutOnce makes no network connections.

| File | One row per | Contents |
|---|---|---|
| `Health.csv` | check (Save, Open, Audit, Manual) | Who, when, trigger, drawing, then the columns below, plus any `HealthExtraCounts` columns |
| `Xrefs.csv` | xref, per Health.csv row | Name, path, Attach/Overlay, Loaded/Unloaded/Not Found, nested, instances, insertion point, rotation, scale, at 0,0,0, insertion units, coordinate system |
| `Labels.csv` | Civil 3D label type and style, per Health.csv row | Label type, label style, how many labels, how many have typed-over text (`n/a` if they could not be checked), how many could not be checked, handles of the typed-over labels |
| `Backups.csv` | backup copy made | Who, when, computer, original drawing, backup copy path, reason, whether unsaved changes were left out. Written even with logging off |
| `Events.csv` | warning raised (also when frequency hides it) | Who, when, drawing, event type, detail. Includes every impact warning (`IMPACT`), guard warning and advisory, standards issues on open, and every TEXT / DTEXT / MTEXT start (`TEXT-TIP` the first time in a session, `TEXT-USED` after that) |
| `Opened.csv` | drawing opened | Who, when, drawing |

**Event codes:** `IMPACT`, `STANDARDS-OPEN`, `EXPLODE-LOSS`, `ATTRIB-LOSS`, `XREF-BIND`, `XREF-MOVED`, `XREF-BASEPOINT`, `SAVE-FLAG`, `COORD-UNITS`, `CLEANUP`, `BACKUP-COPY`, `ADVISORY-REFEDIT`, `ADVISORY-REFCLOSE`, `ADVISORY-PROMOTE`, `TEXT-TIP`, `TEXT-USED`.

**Health.csv columns**

- Identity: `Timestamp, Trigger, User, DrawingPath, DrawingName`
- Tables: `Layers, Linetypes, Blocks, Layouts, RegApps, Styles`
- Civil 3D objects: `Alignments, Profiles, ProfileViews, Surfaces, Corridors, Assemblies, PipeNetworks, GravityPipes, GravityStructures, PressurePipeNetworks, SectionViews, Sections`
- Annotation: `Hatches, TextObjects`
- ByLayer: `ColorNotByLayer, LinetypeNotByLayer, ObjectsNotByLayer, BlockDefColorNotByLayer, BlockDefLinetypeNotByLayer`
- Xrefs: `Xrefs, XrefsBroken, XrefsUnloaded, XrefsOffOrigin`
- Labels: `Labels, LabelsOverridden, LabelsUnchecked`
- Settings: `AngularUnits, InsUnits, DrawingScale, CoordinateSystem, ProjectCoordinateSystem, CoordUnitIssues`

**Health.csv keeps history.** For the latest state of a drawing, filter on `DrawingPath` and take the newest `Timestamp`.

**If a later version changes a log's columns,** the old file is renamed to `<name>-archived-<date>.csv` and a new file starts. Nothing is deleted. 2.1 adds columns to Health.csv and Xrefs.csv, so the first save after upgrading archives both.

Notes:

- `Open` rows are written without the Civil 3D COM connection (it may not be ready while Civil 3D starts), so `Styles` and the settings columns read `n/a` on those rows. `Save` and `Audit` rows have them.
- `XrefsOffOrigin` counts xref inserts in Model Space whose insertion point is not 0,0,0. Paper-space xrefs (title blocks) are ignored.
- `BlockDef*` columns read `n/a` when "Include block definitions" is off.
- `CUTONCE-AUDIT` and `CUTONCE-GUARD-CHECKNOW` always write their rows, even with logging off, because the user asked for them.

## Standards check

| Check | What it counts |
|---|---|
| Objects not ByLayer | Objects in Model Space and every layout whose color, linetype, or either is not ByLayer. ByBlock counts as not ByLayer |
| Inside block definitions | The same, inside named blocks. Anonymous blocks (dynamic, dimension, hatch) and xref-dependent blocks are skipped |
| Xref status | **Loaded**: resolved. **Unloaded**: not loaded, file exists at its saved path, relative to the drawing, or by name in the drawing's folder. **Not Found**: none of those |
| Xref not at 0,0,0 | Xref inserts in Model Space whose insertion point is not 0,0,0, each listed with its coordinates |
| Typed-over labels | Civil 3D labels (surface, station, elevation and every other `AeccDb*Label*` type) whose text has been typed over, so they no longer update with the design. Listed by count, label type and style. See [Typed-over labels](#typed-over-labels) |
| Coordinate system and units | No coordinate system assigned; a coordinate system or insertion units different from the project's (`CutOnce-Project.ini` or `ProjectStandards`); Unitless insertion units; an xref in different units or a different coordinate system |

`CUTONCE-CHECK` runs it at any time and always shows the result.

## Impact warnings

The warning lists the dependent objects and has two buttons:

- **OK** closes the warning. It is information only, because AutoLISP cannot cancel a command from a dialog. To stop the edit, click OK and then press **ESC** at the command's next prompt.
- **Learn More...** opens the matching section of [Civil 3D Warnings Explained](https://designtovisualization.com/kb-c3d-and-cutonce-assistant/).

### MOVE, STRETCH, ROTATE and SCALE

Using any of these on an alignment, profile or surface shows the impact warning:

- **Objects selected first:** the warning appears as the command starts. Click OK, then press ESC to stop.
- **Command first, then select:** the warning appears when the command finishes and says to type **U** to undo.

## Learn More links

Every CutOnce warning has a **Learn More** button that opens its own section of [Civil 3D Warnings Explained](https://designtovisualization.com/kb-c3d-and-cutonce-assistant/). The warning stays open, and the link is also printed on the command line.

| Warning | Topic | Section |
|---|---|---|
| Impact: MOVE / STRETCH / ROTATE / SCALE | `MOVE`, `STRETCH`, `ROTATE`, `SCALE` | `#move-civil-objects`, `#stretch-civil-objects`, `#rotate-civil-objects`, `#scale-civil-objects` |
| Impact: grip edit, alignment selected | `GRIP_ALIGNMENT` | `#grip-edit-alignment` |
| Impact: grip edit, profile selected | `GRIP_PROFILE` | `#grip-edit-profile` |
| Impact: surface-edit command | `SURFACE` | `#surface-edits` |
| Impact: anything else | `GENERAL` | `#dynamic-model` |
| Standards check (always shown) | `STANDARDS_OPEN` | `#standards-check` |
| Standards check: objects not ByLayer | `STD_BYLAYER` | `#objects-not-bylayer` |
| Standards check: xrefs broken or unloaded | `STD_XREF_STATUS` | `#xrefs-broken-unloaded` |
| Standards check: xrefs not at 0,0,0 | `STD_XREF_ORIGIN` | `#xref-not-at-origin` |
| Guard: EXPLODE removed or converted an object | `GUARD_EXPLODE` | `#explode-civil-objects` |
| Guard: EXPLODE / BURST converted attributed blocks | `GUARD_ATTRIB` | `#explode-attributed-blocks` |
| Guard: xref bound | `GUARD_XREF_BIND` | `#xref-bind` |
| Guard: xref moved or copied | `GUARD_XREF_MOVED` | `#xref-moved` |
| Guard (on save): xref not at 0,0,0 | `GUARD_XREF_ORIGIN` | `#xref-not-at-origin` |
| Guard: REFEDIT / REFCLOSE | `GUARD_REFEDIT` | `#refedit` |
| Guard: promoting a data shortcut reference | `GUARD_PROMOTE` | `#promote-reference` |
| Guard: TEXT / DTEXT / MTEXT tip | `GUARD_TEXT` | `#text-instead-of-labels` |
| Guard (on save): unusual growth | `GUARD_GROWTH` | `#drawing-growth` |
| Cleanup (offered on growth, and its dialog) | `GUARD_CLEANUP` | `#drawing-cleanup` |
| Guard (on save): coordinate system / units | `GUARD_COORD_UNITS` | `#coordinate-system-units` |
| Standards check: typed-over labels | `STD_LABEL_OVERRIDE` | `#label-text-overrides` |
| Standards check: coordinate system / units | `STD_COORD_UNITS` | `#coordinate-system-units` |
| Backup copy required but failed | `BACKUP` | `#backup-copies` |
| Control Center | `CONTROL_CENTER` | `#control-center` |

The standards check can find several problems at once, so its dialog shows one button per problem found (for example "Not ByLayer..." and "Broken / unloaded xrefs..."), plus "Reading this check...".

The page address and sections are set by `LearnMoreUrl` and `LearnMoreAnchors` in `CutOnce-Config.lsp`. The 2.1 sections (`#drawing-cleanup`, `#coordinate-system-units`, `#label-text-overrides`, `#backup-copies`) need adding to the knowledge-base page; until they exist, those buttons open the top of the page.

## Cleanup and backup copies

When the save-time growth check fires, its warning has a **Clean up now...** button (switch: `GuardCleanup`). Cleanup runs as soon as that save finishes, so the file on disk is the drawing before cleanup. `CUTONCE-CLEANUP` opens the same dialog at any time.

| Tick box | What runs |
|---|---|
| Unused registered applications | `-PURGE` Regapps |
| Reset the annotation scale list | `-SCALELISTEDIT` Reset, back to the default scale list |
| Unused text, dimension, multileader, table, multiline styles | `-PURGE` for each style type |
| Unused anonymous blocks | `-PURGE` Blocks, anonymous (`*U`, `*D`...) names only |
| Unused Civil 3D styles | `_PURGESTYLES`: Civil 3D's Purge Styles dialog opens during the cleanup, where the designer confirms the unused Civil 3D styles to remove |
| AUDIT | `AUDIT`, fixing errors |
| Save a backup copy first | Copies the drawing to the shared backup folder before anything changes |

- PURGE removes only items nothing uses, and repeats (up to 3 times) while counts keep falling. Command echo is on while cleanup runs, so each `-PURGE`, `-SCALELISTEDIT`, `_PURGESTYLES` and `AUDIT` and its own messages show on the command line (F2). The result lists every command run and, per item, how many were removed, or "nothing unused to remove" when everything of that kind is still in use.
- The whole cleanup is one undo step: type **U** straight afterwards to undo it. The result lists each count before and after, offers **Save now**, and is logged to Events.csv (`CLEANUP`).
- **Backup copies.** The copy is the drawing as last saved. It goes to the shared backup folder with a name nobody else can produce: `<drawing>__<YYYYMMDD-HHMMSS-mmm>_<user>-<computer>.dwg`, plus a `-2`, `-3`... counter if that name still exists, so copies never overwrite each other. Each copy is recorded in `Backups.csv`.
- `BackupBeforeCleanup` sets whether the backup tick box starts ticked. Lock it (`LockedSettings`) to require a backup; if the copy then fails, cleanup stops and nothing changes. Without the lock, a failed copy asks before cleaning up without one.
- **Every CutOnce warning has a Save a copy button**: command warnings (MOVE, STRETCH, ROTATE, SCALE, grip and surface edits, EXPLODE, XREF bind, REFEDIT, promote, TEXT), and the save checks (growth, xref origin, coordinate system / units). It copies the drawing at once, while the warning is still open, so the designer can keep a way back before going ahead. The copy is the drawing as last saved, so it never includes the change being warned about; the warning says when unsaved changes are left out. The button is greyed out for a drawing that has never been saved. The standards report on open has no button, because it changes nothing.
- `CUTONCE-BACKUP` copies the drawing to the backup folder at any time (it offers to save first if there are unsaved changes). `CUTONCE-BACKUP-FOLDER` opens the folder.
- Cleanup is not offered while a drawing is closing (the queued command would land in another drawing).

## Typed-over labels

A label whose text has been typed over (Edit Label Text, then replacing a property field with typed text) keeps that text when the design changes. The standards check on open counts them, lists each label type and style with how many are typed over, and `Labels.csv` records them with their handles.

AutoLISP cannot call Civil 3D's own "is this text overridden" check, so CutOnce reads a label property from the list in `LabelOverrideProperties`. **The CAD administrator should confirm that property once per Civil 3D release** with `CUTONCE-LABEL-PROBE` (steps in `CAD-Admin-Guide.html`). A label type with none of the listed properties is reported as "could not be checked", and `LabelsOverridden` reads `n/a`, never 0.

## Install

Requirements: Civil 3D 2021 or later on 64-bit Windows.

1. Close Civil 3D.
2. Unzip the release and double-click **Install.cmd**.
3. Start Civil 3D and type `CUTONCE-STATUS`, then `CUTONCE`.

This installs to `%APPDATA%\Autodesk\ApplicationPlugins\CutOnce.bundle`, which Civil 3D loads automatically and trusts by default.

| Goal | Command |
|---|---|
| All users on the machine (run as administrator) | `Install.cmd -Scope AllUsers` |
| Choose the log folder | `Install.cmd -LogDir "D:\CAD\CutOnce\Logs"` |
| Shared team log folder, one subfolder per person | `Install.cmd -LogDir "\\server\cad\CutOnce\Logs" -LogSubfolder user-computer` |
| Change the log folder after installing | Double-click **Set-LogFolder.cmd** and follow the steps |
| Shared backup folder for copies made before cleanup | `Install.cmd -BackupDir "\\server\cad\CutOnce\Backups"` |
| Custom install folder, such as a network share | `Install.cmd -InstallDir "\\server\cad\CutOnce"` |

With a custom install folder, the installer prints a `(load ...)` line for acaddoc.lsp. Also add that folder to **Options > Files > Trusted Locations**.

Reinstalling keeps an existing `CutOnce-Config.lsp` and writes the current version next to it as `CutOnce-Config.sample.lsp`. Keys missing from your config use the built-in defaults (everything on), so a reinstall works without editing it.

## Configure (CAD administrators)

**Step-by-step instructions are in `CAD-Admin-Guide.html` in the install package:** adding watched commands, adding data points to Health.csv, sending logs to a shared team folder across offices, the shared backup folder, project coordinate systems, and confirming typed-over label detection.

`CutOnce-Config.lsp`, in the install folder's `Contents`, is plain text with a comment for every setting.

- **Control Center defaults.** Every Control Center setting name can be given a firm default, for example `("StdAlwaysShow" . T)`. Designers get that value until they choose their own.
- **LockedSettings.** List setting names to enforce them for everyone. For example, to require logging: `("LockedSettings" . ("LogEnabled" "LogHealthOnSave" "LogXrefs"))`. `WarnFrequency` can be locked too.
- `WarnFrequency`: `"every"` or `"once"` (once per command per session).
- `ImpactExtraCommands`: more Civil 3D command names to watch (the Control Center's **Other watched commands** row). Confirm a name with `CUTONCE-GUARD-LOGCOMMANDS` first, for example `("ImpactExtraCommands" . ("AECCSOMECOMMAND" "AECCOTHER"))`. The Control Center's **How to add other watched commands...** button walks through it.
- `HealthExtraCounts`: extra Health.csv columns, each counting one or more object types, for example `("HealthExtraCounts" . (("FeatureLines" . "AeccDbFeatureLine") ("Dimensions" . "AcDb*Dimension")))`. Find the type names with `CUTONCE-GUARD-DUMPOBJECTS`. The new columns are also checked for unusual growth on save.
- `LogDir` and `LogSubfolder` (`"user"`, `"computer"` or `"user-computer"`): a shared log folder, with each person writing to their own subfolder so files never collide or make sync conflicts.
- `BackupDir`: the shared "master" folder for backup copies (environment variable `CUTONCE_BACKUPDIR` overrides it). Default: `Documents\CutOnce Backups` per user.
- `ProjectStandards`, or a `CutOnce-Project.ini` file in a project's top folder (`CoordinateSystem=CA83-VIF`, `InsUnits=US Survey Feet`): the coordinate system and units each project should use. `CoordSysRequired` (default `T`): flag drawings with no coordinate system.
- `LabelObjectNames` (default `"AECCDB*LABEL*"`) and `LabelOverrideProperties`: which objects are labels, and which property says a label's text is typed over (confirm with `CUTONCE-LABEL-PROBE`).
- `GuardGrowthWarnPct` (default 20), `LearnMoreUrl`, `LearnMoreAnchors`.

Folder lookup order. Install folder: `CUTONCE_HOME`, then the bundle location. Log folder: `CUTONCE_LOGDIR`, then `LogDir`, then `%LOCALAPPDATA%\CutOnce\Logs\`, plus the subfolder from `CUTONCE_LOGSUBFOLDER`, then `LogSubfolder`. Backup folder: `CUTONCE_BACKUPDIR`, then `BackupDir`, then `Documents\CutOnce Backups`.

## Commands

| Command | Purpose |
|---|---|
| `CUTONCE` | CutOnce Control Center |
| `-CUTONCE` | The same at the command line, for scripts and buttons |
| `CUTONCE-STATUS` | Version, folders, Civil 3D connection, logging on/off |
| `CUTONCE-FINDCIVIL` | Finds the Civil 3D COM version if the connection fails (slow, one-time) |
| `CUTONCE-CHECK` / `CUTONCE-CHECK-STATUS` | Standards check now; its settings |
| `CUTONCE-AUDIT` | Records every open drawing in Health.csv and opens it in Excel |
| `CUTONCE-AUDIT-FOLDER` | Records every .dwg in a folder |
| `CUTONCE-CLEANUP` | Cleanup dialog: purge unused regapps, scales, styles, anonymous blocks; AUDIT; backup copy first |
| `CUTONCE-BACKUP` / `CUTONCE-BACKUP-FOLDER` | Copy this drawing to the shared backup folder now; open that folder |
| `CUTONCE-LABEL-PROBE` | CAD admin: shows which property marks a label's text as typed over |
| `CUTONCE-GUARD-STATUS` / `-CHECKNOW` / `-SUMMARY` / `-LOG` | Guard switches, health check now, history rollup, log paths |
| `CUTONCE-GUARD-DUMPOBJECTS` | Counts of every object type by name, for checking a number against Toolspace or naming a `HealthExtraCounts` column |
| `CUTONCE-GUARD-LOGCOMMANDS` | Prints every command name as it runs |
| `CUTONCE-IMPACT-ON` / `-OFF` | Command warnings (master switch) on or off |
| `CUTONCE-IMPACT-STATUS` / `-DEBUG` | Impact status, and diagnostic tracing |

## Performance

- **One scan per check.** The standards check, ByLayer counts, xref status and object counts come from a single pass over Model Space and the layouts. Block definitions add a second pass; switch off "Include block definitions" on very large drawings.
- **Open.** The scan runs once and feeds both the standards dialog and the Health.csv row. Turn off both "Run the standards check" and "Health.csv row when a drawing opens" to skip it.
- **Save.** Skipped entirely when logging, the growth check and the 0,0,0 check are all off.
- **Guards** take no snapshot when switched off.
- **Civil 3D connection** is cached across drawings and sessions.

## Known limitations

- AutoLISP cannot cancel a command from a dialog, so warnings only inform. Stop the edit with ESC after clicking OK.
- Surface edits started from Toolspace's right-click menu do not raise a command event, so they are not seen.
- Only these Civil 3D commands are watched: `AECCRAISELOWERSURFACE`, `AECCADDSURFACELINE`, `AECCDELETESURFACELINE`, `AECCADDSURFACEPOINT`, `AECCDELETESURFACEPOINT`, `AECCEDITSURFACEPOINT`, `AECCMOVESURFACEPOINT`, `AECCEDITSURFACESWAPEDGE`. Grip edits of alignments and profiles are watched.
- Data shortcut references (DREFs) are not checked for broken sources. Use Prospector > Data Shortcuts.
- New, unsaved drawings are not checked or logged on open. Run `CUTONCE-CHECK` by hand.
- In `CUTONCE-AUDIT`, drawings other than the one you started it from report xref Type as blank (attach/overlay cannot be read through COM).
- Pipe proximity uses bounding boxes, so treat it as "worth checking".
- Typed-over label detection depends on a label property confirmed with `CUTONCE-LABEL-PROBE` (see [Typed-over labels](#typed-over-labels)). Labels that cannot be checked are reported as such.
- An xref's coordinate system is read only when the xref is loaded and its geographic location can be read; otherwise that xref is not compared.
- Civil 3D styles are purged through Civil 3D's own `_PURGESTYLES` dialog (there is no command-line version), so the designer confirms them there.
- Cleanup offered from the growth warning is queued to start after the save; if it does not start, type `CUTONCE-CLEANUP`.

## Uninstall

Double-click **Uninstall.cmd**. Add `-RemoveLogs` to delete logs as well. Each designer's Control Center choices are removed.
