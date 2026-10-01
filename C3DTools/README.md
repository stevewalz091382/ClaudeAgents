# C3DTools for Civil 3D

C3DTools contains three AutoLISP tools that load into every drawing:

| Tool | What it does | Interrupts the user? |
|---|---|---|
| **C3DGuard** | Warns when EXPLODE, BURST, XREF bind or moving an xref destroys data. Logs a health snapshot on every save and flags unusual growth. | Only when something risky happens |
| **C3DAudit** | Keeps a per-drawing audit report (layers, blocks, styles, Civil 3D object counts, xrefs, settings) up to date after every save | Never |
| **C3DImpact** | Before an alignment, surface or profile is edited, lists what depends on it (corridors, profiles, sample lines, sheets, pipes nearby) | Shows a dialog on grip edits and surface edits |

## Command interception (opt-in)

C3DImpact can also intercept **MOVE, STRETCH, ROTATE and SCALE**. This is **off by default**, and no AutoCAD command is changed unless a user turns it on.

When a user runs `C3D-IMPACT-INTERCEPT`, a dialog explains the change and asks for confirmation. If they enable it, C3DTools:

- runs `UNDEFINE` on those four commands for the session, and replaces them with versions that show the impact dialog first. Cancel blocks the command. Accept Risk runs the original command unchanged.
- remembers the choice for that user. Running `C3D-IMPACT-INTERCEPT` again turns it off and restores the commands immediately.

Side effects while it is on:

- Other LISP routines, scripts or macros that call these commands **without** the `_.` prefix get the C3DTools version.
- Macros that use `_.MOVE` and similar bypass interception.

Nothing persists outside the session: `UNDEFINE` resets when Civil 3D closes, and uninstalling removes the stored preference.

CAD administrators control this in `C3DTools-Config.lsp`:

- `("ImpactInterceptAllowed" . nil)` prevents anyone from enabling it.
- `("ImpactInterceptDefault" . T)` turns it on for users who have not made their own choice.

To give users a one-click button, add a ribbon or toolbar button with the macro `^C^CC3D-IMPACT-INTERCEPT`.

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
| `ImpactInterceptAllowed` | on | Whether users may enable interception |
| `ImpactInterceptDefault` | off | Interception for users who have not chosen |
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
| `C3D-IMPACT-INTERCEPT` | Turns MOVE/STRETCH/ROTATE/SCALE interception on or off (see above) |
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

- AutoLISP cannot cancel a Civil 3D command or grip drag that has already started. For those, Cancel asks the user to press ESC. MOVE, STRETCH, ROTATE and SCALE (when interception is on) are blocked properly.
- Surface edits started from Toolspace's right-click menu do not raise a command event, so neither Guard nor Impact sees them.
- Only these Civil 3D commands are watched, because they are the names observed in a live session: `AECCRAISELOWERSURFACE`, `AECCADDSURFACELINE`, `AECCDELETESURFACELINE`, `AECCADDSURFACEPOINT`, `AECCDELETESURFACEPOINT`, `AECCEDITSURFACEPOINT`, `AECCMOVESURFACEPOINT` and `AECCEDITSURFACESWAPEDGE`. Alignment and profile editor commands are not watched until their names are confirmed. Grip edits of alignments and profiles are watched.
- Pipe proximity uses bounding boxes, so treat it as "worth checking".
- C3DAudit's alignment, corridor and pipe-network counts come from Civil 3D COM collections that may not exist on every release, and they read 0 where missing. Check them against Toolspace with `C3DGUARD-DUMPOBJECTS`.

## Uninstall

Double-click **Uninstall.cmd**. Add `-RemoveLogs` to delete logs and reports as well.
