# C3DTools for Civil 3D

Publisher: Stephen Walz

C3DTools contains three AutoLISP tools that load into every drawing:

| Tool | What it does | Interrupts the user? |
|---|---|---|
| **C3DGuard** | Warns when EXPLODE, BURST, XREF bind or moving an xref destroys data. Logs a health snapshot on every save and flags unusual growth. | Only when something risky happens |
| **C3DAudit** | Keeps a per-drawing audit report (layers, blocks, styles, Civil 3D object counts, xrefs, settings) up to date after every save | Never |
| **C3DImpact** | Before an alignment, surface or profile is edited, lists what depends on it (corridors, profiles, sample lines, sheets, pipes nearby) | Shows a warning on grip edits, surface edits and MOVE/STRETCH/ROTATE/SCALE of those objects, every time or once per session (user's choice) |

## Impact warnings

The warning lists the dependent objects and has two buttons:

- **OK** closes the warning. It is information only, because AutoLISP cannot cancel a command from a dialog. To stop the edit, click OK and then press **ESC** at the command's next prompt.
- **Learn More...** opens the [C3D Guard Change-Impact knowledge-base page](https://designtovisualization.com/kb-tools-for-civil-3d-%c2%b7-c3d-guard-change-impact/) in the default browser, at the section for the command that raised the warning. The warning stays open. The link is also printed on the command line.

Each warning links to its own section, following the page's "Linking warnings to articles" table:

| Warning | Section |
|---|---|
| MOVE / STRETCH / ROTATE / SCALE (intercepted) | `#move-civil-objects`, `#stretch-civil-objects`, `#rotate-civil-objects`, `#scale-civil-objects` |
| Grip edit with an alignment selected | `#grip-edit-alignment` |
| Grip edit with a profile selected | `#grip-edit-profile` |
| Any surface-edit command | `#surface-edits` |
| Anything else (no single object) | `#dynamic-model` |
| Guard tip on TEXT / DTEXT / MTEXT | `#text-instead-of-labels` |
| Guard warning when an xref is moved or copied | `#xref-moved` |
 The page address and section anchors are set by `LearnMoreUrl` and `LearnMoreAnchors` in `C3DTools-Config.lsp`.

Each user chooses in `C3D-IMPACT-SETTINGS` whether warnings appear:

- **Every time** the command runs (default), or
- **Once per command, per Civil 3D session.** After the first warning for a command, later uses run without the dialog until Civil 3D is restarted. All grip edits count as one command.

Warnings can also be switched off entirely, in the same dialog or with `C3D-IMPACT-OFF`.

## MOVE, STRETCH, ROTATE and SCALE

Using any of these commands on an alignment, profile or surface shows the impact warning. Nothing is undefined for this:

- **Objects selected first, then the command:** the warning appears as the command starts. Click OK, then press ESC to stop.
- **Command first, then select:** the warning appears when the command finishes, listing what was affected, and says to type **U** to undo.

To get the warning before the edit in the second case as well, turn on interception (below).

## Command interception (opt-in)

C3DImpact can also intercept **MOVE, STRETCH, ROTATE and SCALE**, each one separately. All four are **off by default**, and no AutoCAD command is changed unless a user ticks it.

`C3D-IMPACT-SETTINGS` has a tick box for each command, next to an explanation of what interception does. For each ticked command, C3DTools:

- runs `UNDEFINE` on that command for the session, and replaces it with a version that shows the impact warning first and then runs the original command unchanged.
- remembers the choice for that user. Unticking restores the original command immediately.

Side effects while a command is ticked:

- Other LISP routines, scripts or macros that call these commands **without** the `_.` prefix get the C3DTools version.
- Macros that use `_.MOVE` and similar bypass interception.

UNDEFINE affects every open drawing, so C3DTools defines its own MOVE, STRETCH, ROTATE and SCALE in every drawing it loads into. While AutoCAD's command is defined, AutoCAD always uses its own and these do nothing. After a command is undefined, they keep it working in every drawing: intercepted if the user ticked it, otherwise passed straight to the AutoCAD command. Each drawing also restores any command the user has not ticked when it opens. If MOVE or any of the others ever stops responding, type `C3D-IMPACT-RESTORE`.

Nothing persists outside the session: `UNDEFINE` resets when Civil 3D closes, and uninstalling removes the stored preference.

CAD administrators control this in `C3DTools-Config.lsp`:

- `("ImpactInterceptAllowed" . nil)` prevents anyone from enabling it.
- `("ImpactInterceptDefault" . T)` turns on all four for users who have not made their own choice, and `("ImpactInterceptDefault" . ("MOVE" "ROTATE"))` turns on just those listed.
- `("ImpactWarnFrequency" . "once")` makes once-per-session the default warning frequency.

One-click buttons: use `^C^CC3D-IMPACT-SETTINGS` to open the dialog. The command-line version `-C3D-IMPACT-SETTINGS` toggles one item per keyword, so a button with `^C^C-C3D-IMPACT-SETTINGS;Move;X;` toggles MOVE interception. The keywords are Move, Stretch, Rotate, Scale, Warnings and Frequency.

## Install

Requirements: Civil 3D 2021 or later on 64-bit Windows.

1. Close Civil 3D.
2. Unzip the release and double-click **Install.cmd**.
3. Start Civil 3D and type `C3DTOOLS-STATUS`.

This installs to `%APPDATA%\Autodesk\ApplicationPlugins\C3DTools.bundle`, which Civil 3D loads automatically and trusts by default. You do not need to change acaddoc.lsp, the support path or trusted locations.

Other options (run `Install.ps1` from PowerShell, or pass the same switches to `Install.cmd`):

| Goal | Command |
|---|---|
| All users on the machine (run as administrator) | `Install.cmd -Scope AllUsers` |
| Choose the log folder | `Install.cmd -LogDir "D:\CAD\C3DTools\Logs"` |
| Custom install folder, such as a network share | `Install.cmd -InstallDir "\\server\cad\C3DTools"` |

With a custom install folder, the installer prints a `(load ...)` line for you to add to acaddoc.lsp. You also need to add that folder to **Options > Files > Trusted Locations**.

Reinstalling or upgrading keeps an existing `C3DTools-Config.lsp`.

### Upgrading from the trial scripts

Remove the old `(load "C:/Civil3DTools/...")` lines from acaddoc.lsp and any Startup Suite entries for `C3DGUARD.lsp`, `C3DAUDIT.lsp` and `Civil3D-ImpactAgent.lsp`. C3DTools warns at load if it finds them still loaded. Logs no longer go to `C:\Civil3DTools\C3DGuard\`. Copy old CSVs to the new log folder if you want to keep the history.

## Configure

Settings live in `C3DTools-Config.lsp`, in the install folder's `Contents`. It is a plain-text file and has a comment for every setting.

| Setting | Default | Meaning |
|---|---|---|
| `LogDir` | `%LOCALAPPDATA%\C3DTools\Logs\` | Where logs and reports go. The `C3DTOOLS_LOGDIR` environment variable overrides it. |
| `GuardGrowthWarnPct` | `20` | Growth between saves that triggers a warning |
| `AuditOnSave` | on | Re-audit the saved drawing after each save |
| `ImpactWarnings` | on | Impact dialog for grip edits and surface edits |
| `ImpactWarnFrequency` | `"every"` | `"every"` or `"once"` per command per session, for users who have not chosen |
| `ImpactInterceptAllowed` | on | Whether users may enable interception |
| `ImpactInterceptDefault` | off | Interception for users who have not chosen: `nil`, `T` (all four), or a list of commands |
| `ImpactExtraCommands` | none | More Civil 3D command names to watch. Confirm a name with `C3DGUARD-LOGCOMMANDS` before adding it. |

Folder lookup order. Install folder: `C3DTOOLS_HOME`, then the bundle location. Log folder: `C3DTOOLS_LOGDIR`, then `LogDir`, then the default.

## Commands

| Command | Purpose |
|---|---|
| `C3DTOOLS-STATUS` | Version, folders, Civil 3D connection |
| `C3DTOOLS-FINDCIVIL` | Finds the Civil 3D COM version if the connection fails (slow, one-time) |
| `C3DGUARD-STATUS` / `-CHECKNOW` / `-SUMMARY` / `-LOG` | Guard status, health check now, history rollup, log paths |
| `C3DGUARD-DUMPOBJECTS` | Raw object counts, for checking a number against Toolspace |
| `C3DGUARD-LOGCOMMANDS` | Prints every command name as it runs, for finding a ribbon command's real name |
| `C3DAUDIT` | Audits all open drawings and opens the report in Excel |
| `C3DAUDIT-FOLDER` | Audits every .dwg in a folder |
| `C3D-IMPACT-ON` / `-OFF` | Impact warnings on or off |
| `C3D-IMPACT-SETTINGS` | Dialog: warnings on/off, every time or once per session, interception of each command |
| `-C3D-IMPACT-SETTINGS` | The same at the command line, for macros and scripts |
| `C3D-IMPACT-INTERCEPT` | Older name for `C3D-IMPACT-SETTINGS` |
| `C3D-IMPACT-RESTORE` | Turns all interception off and restores MOVE, STRETCH, ROTATE and SCALE (their warnings keep working) |
| `C3D-IMPACT-STATUS` / `-DEBUG` | Status, and diagnostic tracing (off by default) |

## Files written

All files go to the log folder, none to the drawing's folder:

- `Health.csv`: one row per save
- `Events.csv`: one row per warning
- `Opened.csv`: one row per drawing opened
- `Civil3D_Audit_Report.csv` and `Civil3D_Audit_XrefDetail.csv`: the latest audit of each drawing

These files contain drawing paths and names. C3DTools makes no network connections.

## Performance

- **Civil 3D connection.** The first connection tries a short list of versions, then remembers the one that works for later drawings and future sessions. The full registry scan only runs when you type `C3DTOOLS-FINDCIVIL`.
- **Audit on save.** Runs after the save completes, covers only the drawing that was saved, and caches which style collections exist.
- **Guard on save.** Reads `Health.csv` only on the first save of each session.
- **Impact.** Scans Model Space once per dialog instead of once per object analysed.

## Known limitations

- AutoLISP cannot cancel a command from a dialog, so the warning only informs. The user stops the edit with ESC after clicking OK.
- With STRETCH intercepted and nothing pre-selected, C3DTools asks for the selection itself and passes it to STRETCH. STRETCH then moves whole objects rather than stretching a crossing window. Pre-select with a crossing window, or leave STRETCH unticked.
- Surface edits started from Toolspace's right-click menu do not raise a command event, so neither Guard nor Impact sees them.
- Only these Civil 3D commands are watched, because they are the names observed in a live session: `AECCRAISELOWERSURFACE`, `AECCADDSURFACELINE`, `AECCDELETESURFACELINE`, `AECCADDSURFACEPOINT`, `AECCDELETESURFACEPOINT`, `AECCEDITSURFACEPOINT`, `AECCMOVESURFACEPOINT` and `AECCEDITSURFACESWAPEDGE`. Alignment and profile editor commands are not watched until their names are confirmed. Grip edits of alignments and profiles are watched.
- Pipe proximity uses bounding boxes, so treat it as "worth checking".
- C3DAudit's alignment, corridor and pipe-network counts come from Civil 3D COM collections that may not exist on every release, and they read 0 where missing. Check them against Toolspace with `C3DGUARD-DUMPOBJECTS`.

## Uninstall

Double-click **Uninstall.cmd**. Add `-RemoveLogs` to delete logs and reports as well.
