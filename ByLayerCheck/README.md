# ByLayerCheck for Civil 3D

Publisher: Stephen Walz

ByLayerCheck checks each drawing as it opens and warns you about:

| Check | What it counts |
|---|---|
| **Objects not ByLayer** | Objects in model space and every layout whose color, linetype, or either is not ByLayer. ByBlock counts as not ByLayer. |
| **Inside block definitions** | The same color and linetype checks inside named blocks. Anonymous blocks (dynamic, dimension, hatch) are skipped because they are ByBlock by design. |
| **XREFs** | Total xrefs, broken ones (file not found), and unloaded ones |

The dialog appears only when something is wrong, unless `AlwaysShow` is on. The results are also printed on the command line every time.

## Install

Requirements: Civil 3D 2021 or later on 64-bit Windows (built for Civil 3D 2027).

1. Close Civil 3D.
2. Unzip the release and double-click **Install.cmd**.
3. Start Civil 3D, open a drawing and type `BLCHECK-STATUS`.

This installs to `%APPDATA%\Autodesk\ApplicationPlugins\ByLayerCheck.bundle`, which Civil 3D loads automatically and trusts by default. You do not need to change acaddoc.lsp, the support path or trusted locations.

Other options (run `Install.ps1` from PowerShell, or pass the same switches to `Install.cmd`):

| Goal | Command |
|---|---|
| All users on the machine (run as administrator) | `Install.cmd -Scope AllUsers` |
| Custom install folder, such as a network share | `Install.cmd -InstallDir "\\server\cad\ByLayerCheck"` |

With a custom install folder, the installer prints a `(load ...)` line for you to add to acaddoc.lsp. You also need to add that folder to **Options > Files > Trusted Locations**.

Reinstalling or upgrading keeps an existing `ByLayerCheck-Config.lsp`.

If you loaded the earlier single-file `ByLayerCheck.lsp` from acaddoc.lsp or the Startup Suite, remove that entry, or the check runs twice.

## Configure

Settings live in `ByLayerCheck-Config.lsp`, in the install folder's `Contents`. It is plain text, with a comment for every setting.

| Setting | Default | Meaning |
|---|---|---|
| `CheckOnOpen` | on | Run the check when a saved drawing opens |
| `AlwaysShow` | off | Show the dialog even when nothing is wrong |
| `ScanBlocks` | on | Also check inside named block definitions |

## Commands

| Command | Purpose |
|---|---|
| `BLCHECK` | Run the check now and always show the dialog |
| `BLCHECK-STATUS` | Version, install folder and current settings |

## How xrefs are classed

- **Loaded:** resolved by AutoCAD.
- **Unloaded:** not loaded, but the file exists at its saved path, relative to the drawing, or by name in the drawing's folder.
- **Broken:** not loaded and the file cannot be found in any of those places.

## Known limitations

- Civil 3D data shortcut references (DREFs) are not checked. AutoLISP cannot reliably tell whether a Civil 3D object is a data reference or whether its source is broken. Use Prospector > Data Shortcuts, or the out-of-date notifications in Civil 3D, for those.
- New, unsaved drawings (Drawing1.dwg) are not checked on open. Run `BLCHECK` in them by hand.
- ByLayerCheck writes no files and makes no network connections.

## Uninstall

Double-click **Uninstall.cmd**.
