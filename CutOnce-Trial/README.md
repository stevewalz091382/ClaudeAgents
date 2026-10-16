# CutOnce 2.0 Trial for Civil 3D

Publisher: Stephen Walz

Copyright (c) 2026 Stephen Walz. All rights reserved.

**This is the CutOnce Trial.** It includes one feature: the **EXPLODE / BURST warning**, with its switch in the CutOnce Control Center.

> **To unlock the full version, reach out to stevewalz@hotmail.com**
>
> The full version adds standards checks on open, Health.csv / Xrefs.csv / Events.csv logs, change-impact warnings for MOVE / STRETCH / ROTATE / SCALE, grip and surface edits, xref bind / move guards, REFEDIT and promote advisories, and CAD-administrator controls.

## What the trial does

When EXPLODE (or BURST, which runs EXPLODE internally) turns any of these into plain geometry, CutOnce shows a warning right after the command:

- Civil 3D objects (alignments, profiles, surfaces, corridors, pipes, parcels, feature lines and any other AECC object)
- Block references
- Hatches
- Attributed blocks (the attribute data is lost; only the displayed text remains)

The warning lists what was lost, and its **Learn More...** button opens the matching section of [Civil 3D Warnings Explained](https://designtovisualization.com/kb-c3d-and-cutonce-assistant/). Type **U** straight after to undo the explode.

AutoLISP cannot cancel a command from a dialog, so the warning tells you after the fact. Undo puts everything back.

## CutOnce Control Center (Trial)

Type `CUTONCE`.

| Setting | Choices |
|---|---|
| EXPLODE / BURST warning | On / off |
| How often | Every time, or once per command per Civil 3D session |

The dialog also has **Reset to defaults**, **Learn More...**, and an **Email about the full version...** button.

Choices are stored in each designer's AutoCAD profile and apply to every open drawing immediately.

Command-line version, for scripts and toolbar buttons: `-CUTONCE`. Type `WarnEXPLODE` to toggle the warning, or `List`, `Frequency`, `Defaults`, `eXit`.

| Button macro | Effect |
|---|---|
| `^C^C-CUTONCE;WarnEXPLODE;;` | Toggle the EXPLODE warning |

## Commands

| Command | Purpose |
|---|---|
| `CUTONCE` | CutOnce Control Center (Trial) |
| `-CUTONCE` | The same at the command line |
| `CUTONCE-STATUS` | Version, install folder and current settings |

## Install

Requirements: Civil 3D 2024 or later on 64-bit Windows.

1. Close Civil 3D.
2. Unzip the trial and double-click **Install.cmd**.
3. Start Civil 3D and type `CUTONCE-STATUS`, then `CUTONCE`.

This installs to `%APPDATA%\Autodesk\ApplicationPlugins\CutOnce.bundle`, which Civil 3D loads automatically and trusts by default. For every user on the machine, run `Install.cmd -Scope AllUsers` as administrator.

Installing the full version later replaces the trial in place. Your EXPLODE settings carry over.

## Configure

`CutOnce-Config.lsp`, in the install folder's `Contents`, sets the defaults a designer gets until they choose their own: `WarnEXPLODE` (`T` or `nil`) and `WarnFrequency` (`"every"` or `"once"`).

## Uninstall

Double-click **Uninstall.cmd**. Each designer's Control Center choices are removed.

---

**To unlock the full version, reach out to stevewalz@hotmail.com**
