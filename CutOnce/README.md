# CutOnce 2.0 for Civil 3D

Publisher: Stephen Walz

CutOnce keeps Civil 3D models healthy while designers work. It does three things:

- **Guard.** Catches data-loss moves (EXPLODE, xref binds, moved xrefs) and shows what an edit will break before it happens.
- **Learn.** Every warning explains why it matters and links to a knowledge-base article for that exact situation.
- **Insights.** Logs model health on every open and save, so teams can see trends across drawings, projects and people.

CutOnce is one AutoLISP package that loads into every drawing. Each designer decides what runs for them in the **CutOnce Control Center**.

| Part | What it does | Interrupts the user? |
|---|---|---|
| **Standards check** | When a drawing opens: objects not ByLayer, xrefs broken or unloaded, xrefs not at 0,0,0 | Only when something is wrong (or always, if the designer chooses) |
| **Health log** | Writes a Health.csv row (and Xrefs.csv detail) on every save and open: counts, styles, ByLayer, xrefs, drawing settings | Never |
| **Guard** | Warns when EXPLODE (of Civil 3D objects, blocks or hatches), BURST, XREF bind, or moving an xref destroys data. Flags unusual growth and xrefs off 0,0,0 on save | Only when something risky happens |
| **Impact** | Before an alignment, surface or profile is edited, lists what depends on it | On grip edits, surface edits and MOVE/STRETCH/ROTATE/SCALE of those objects |
| **CutOnce Control Center** | One dialog to switch every item above on or off, per designer, including logging | Only when opened |

## CutOnce Control Center

Type `CUTONCE`.

| Group | Switches |
|---|---|
| Command warnings | Master on/off, every time or once per command per session, then one row per command (below) |
| Checks on save | Unusual growth, xref not at 0,0,0 |
| Standards check on open | Run on open, ByLayer, xref status (broken/unloaded), xref not at 0,0,0, always show result, include block definitions |
| Logging | Master on/off, then Health.csv on save, Health.csv on open, Xrefs.csv, Events.csv, Opened.csv |

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

Setting names: `CommandWarnings`, `WarnMOVE`, `WarnCOPY`, `WarnSTRETCH`, `WarnROTATE`, `WarnSCALE`, `WarnEXPLODE`, `WarnXREFBIND`, `WarnREFEDIT`, `WarnPROMOTE`, `WarnTEXT`, `WarnDTEXT`, `WarnMTEXT`, `WarnGRIPS`, `WarnSURFACE`, `WarnOTHER`, `GuardGrowth`, `GuardXrefOrigin`, `StdCheckOnOpen`, `StdByLayer`, `StdXrefStatus`, `StdXrefOrigin`, `StdAlwaysShow`, `StdScanBlocks`, `LogEnabled`, `LogHealthOnSave`, `LogHealthOnOpen`, `LogXrefs`, `LogEvents`, `LogOpened`.

## Logs

All files go to the log folder (see `CUTONCE-STATUS`), none to the drawing's folder. CutOnce makes no network connections.

| File | One row per | Contents |
|---|---|---|
| `Health.csv` | check (Save, Open, Audit, Manual) | Who, when, trigger, drawing, then the columns below |
| `Xrefs.csv` | xref, per Health.csv row | Name, path, Attach/Overlay, Loaded/Unloaded/Not Found, nested, instances, insertion point, rotation, scale, at 0,0,0 |
| `Events.csv` | warning raised (also when frequency hides it) | Who, when, drawing, event type, detail. Includes every impact warning (`IMPACT`), guard warning and advisory, standards issues on open, and every TEXT / DTEXT / MTEXT start (`TEXT-TIP` the first time in a session, `TEXT-USED` after that) |
| `Opened.csv` | drawing opened | Who, when, drawing |

**Event codes:** `IMPACT`, `STANDARDS-OPEN`, `EXPLODE-LOSS`, `ATTRIB-LOSS`, `XREF-BIND`, `XREF-MOVED`, `XREF-BASEPOINT`, `SAVE-FLAG`, `ADVISORY-REFEDIT`, `ADVISORY-REFCLOSE`, `ADVISORY-PROMOTE`, `TEXT-TIP`, `TEXT-USED`.

**Health.csv columns**

- Identity: `Timestamp, Trigger, User, DrawingPath, DrawingName`
- Tables: `Layers, Linetypes, Blocks, Layouts, RegApps, Styles`
- Civil 3D objects: `Alignments, Profiles, ProfileViews, Surfaces, Corridors, Assemblies, PipeNetworks, GravityPipes, GravityStructures, PressurePipeNetworks, SectionViews, Sections`
- Annotation: `Hatches, TextObjects`
- ByLayer: `ColorNotByLayer, LinetypeNotByLayer, ObjectsNotByLayer, BlockDefColorNotByLayer, BlockDefLinetypeNotByLayer`
- Xrefs: `Xrefs, XrefsBroken, XrefsUnloaded, XrefsOffOrigin`
- Settings: `AngularUnits, ImperialToMetricConversion, CoordinateSystem, InsUnits, DrawingScale`

**Health.csv keeps history.** For the latest state of a drawing, filter on `DrawingPath` and take the newest `Timestamp`.

**If a later version changes a log's columns,** the old file is renamed to `<name>-archived-<date>.csv` and a new file starts. Nothing is deleted.

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
| Control Center | `CONTROL_CENTER` | `#control-center` |

The standards check can find several problems at once, so its dialog shows one button per problem found (for example "Not ByLayer..." and "Broken / unloaded xrefs..."), plus "Reading this check...".

The page address and sections are set by `LearnMoreUrl` and `LearnMoreAnchors` in `CutOnce-Config.lsp`.

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
| Custom install folder, such as a network share | `Install.cmd -InstallDir "\\server\cad\CutOnce"` |

With a custom install folder, the installer prints a `(load ...)` line for acaddoc.lsp. Also add that folder to **Options > Files > Trusted Locations**.

Reinstalling keeps an existing `CutOnce-Config.lsp` and writes the current version next to it as `CutOnce-Config.sample.lsp`. Keys missing from your config use the built-in defaults (everything on), so a reinstall works without editing it.

## Configure (CAD administrators)

`CutOnce-Config.lsp`, in the install folder's `Contents`, is plain text with a comment for every setting.

- **Control Center defaults.** Every Control Center setting name can be given a firm default, for example `("StdAlwaysShow" . T)`. Designers get that value until they choose their own.
- **LockedSettings.** List setting names to enforce them for everyone. For example, to require logging: `("LockedSettings" . ("LogEnabled" "LogHealthOnSave" "LogXrefs"))`. `WarnFrequency` can be locked too.
- `WarnFrequency`: `"every"` or `"once"` (once per command per session).
- `ImpactExtraCommands`: more Civil 3D command names to watch (the Control Center's **Other watched commands** row). Confirm a name with `CUTONCE-GUARD-LOGCOMMANDS` first, for example `("ImpactExtraCommands" . ("AECCSOMECOMMAND" "AECCOTHER"))`. The Control Center's **How to add other watched commands...** button walks through it.
- `GuardGrowthWarnPct` (default 20), `LogDir`, `LearnMoreUrl`, `LearnMoreAnchors`.

Folder lookup order. Install folder: `CUTONCE_HOME`, then the bundle location. Log folder: `CUTONCE_LOGDIR`, then `LogDir`, then `%LOCALAPPDATA%\CutOnce\Logs\`.

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
| `CUTONCE-GUARD-STATUS` / `-CHECKNOW` / `-SUMMARY` / `-LOG` | Guard switches, health check now, history rollup, log paths |
| `CUTONCE-GUARD-DUMPOBJECTS` | Raw object counts, for checking a number against Toolspace |
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

## Uninstall

Double-click **Uninstall.cmd**. Add `-RemoveLogs` to delete logs as well. Each designer's Control Center choices are removed.
