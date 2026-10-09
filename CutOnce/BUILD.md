# Building and releasing CutOnce

The six source files in `src/` are compiled into a single `CutOnce.vlx`. The VLX needs AutoCAD or Civil 3D on Windows, because only the AutoLISP compiler inside the product can build one.

## 1. Check the sources (any machine)

```
python tools/check_lisp.py
```

The script checks parenthesis balance, unterminated strings, unprefixed function or global names, and leftover development notes. It does not run the code.

## 2. Test from source (Civil 3D)

1. Run `Install.cmd -AllowSource` from this folder. This installs the bundle with the `.lsp` sources instead of a VLX.
2. Start Civil 3D and open a drawing. The command line should show `CutOnce 2.0.0 loaded` and the note `loading development sources`.
3. Work through the smoke test in section 5.

## 3. Compile the VLX (Civil 3D)

1. Start Civil 3D and type `MAKELISPAPP`.
2. **Application location:** this repo's `CutOnce.bundle\Contents` folder. **Application name:** `CutOnce`.
3. **Application options:** leave **Separate Namespace** unchecked. The tools use per-drawing reactors and globals and are written for the document namespace. Check **ActiveX Support**.
4. **LISP files to include**, in this order:
   1. `src\CutOnce-Core.lsp`
   2. `src\CutOnce-Standards.lsp`
   3. `src\CutOnce-Health.lsp`
   4. `src\CutOnce-Guard.lsp`
   5. `src\CutOnce-Impact.lsp`
   6. `src\CutOnce-ControlCenter.lsp` (must be last: it runs the open-time check once everything else is loaded)
5. **Resource files:** none. The dialog DCL is generated at run time.
6. **Compilation options:** Standard.
7. Finish. The wizard writes `CutOnce.vlx` and a `CutOnce.prv` make file. Commit the `.prv` so later builds can use *Rebuild from make file*. Do not commit the `.vlx`.
8. Uninstall the source test install (`Uninstall.cmd`), then install the VLX build with `Install.cmd` and repeat the smoke test.

## 4. Package

```
powershell -ExecutionPolicy Bypass -File build\Make-Release.ps1
```

This produces `dist\CutOnce-<version>.zip` with the bundle (loader, config, VLX, manifest), the installers and `README.md`. The sources are left out.

The publisher is set to Stephen Walz in `CutOnce.bundle\PackageContents.xml`. Bump `AppVersion` there, and `*cutonce:version*` in `src\CutOnce-Core.lsp`, for each release. Keep `UpgradeCode` the same across all releases.

## 5. Smoke test (each Civil 3D release you support)

| Check | Expected |
|---|---|
| `CUTONCE-STATUS` | Version 2.0.0, install and log folders shown. Civil 3D COM connected. |
| `CUTONCE` | The CutOnce Control Center opens. Locked settings appear greyed out. |
| `-CUTONCE`, then `WarnEXPLODE`, then `X` | The EXPLODE warning toggles. |
| Select an alignment, then `MOVE` | The warning appears before MOVE asks for a base point. |
| Frequency "Every time": run `TEXT`, `MTEXT`, then `TEXT` again | The label style tip shows each time. |
| Frequency "Once per command per session": `EXPLODE` a hatch twice, `MOVE` an xref twice, `TEXT` twice | Each warning shows the first time only. `Events.csv` has a row for every attempt. |
| Untick MOVE in the Control Center | MOVE of an alignment shows nothing. |
| Control Center: How to add other watched commands... | Instructions open, with the config path and the commands added so far. |
| On any warning, click Learn More..., then OK | The browser opens the matching section of Civil 3D Warnings Explained. |
| `EXPLODE` an alignment, then `U` | Guard warning, and a row in `Events.csv`. |
| Open a drawing with a non-ByLayer object or a broken xref | The standards check reports it on open. |
| Save | A row in `Health.csv`. |
| `HealthExtraCounts` set to `(("Dimensions" . "AcDb*Dimension"))`, restart, save | Old Health.csv archived; new file has a `Dimensions` column matching `CUTONCE-GUARD-DUMPOBJECTS`. |
| `Set-LogFolder.cmd` to a network share, option 1, restart | `CUTONCE-STATUS` shows `<share>\<user>-<computer>\`; a save writes Health.csv there. |
| `Uninstall.cmd -RemoveLogs` with that share set | The share is kept. |

## 6. Before listing publicly

- [ ] **Legal review of the Health logging.** The trial version described itself as recreating an existing Power BI dashboard, built around specific project drawings. If that dashboard, its metric set or its column names belong to HDR (or any other employer or client), counsel needs to clear C3DAudit before it is listed. Removing that wording from the comments does not settle the question. Also confirm who owns the code in all four tools, given the employment and IP-assignment terms in force while it was written.
- [ ] Support contact and privacy statement for the store listing. The tools write drawing paths and names to local CSV files. They make no network calls.
- [ ] Smoke test passed on every Civil 3D release named in the listing.
