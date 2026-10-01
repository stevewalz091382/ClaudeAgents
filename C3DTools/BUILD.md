# Building and releasing C3DTools

The four source files in `src/` are compiled into a single `C3DTools.vlx`. The VLX needs AutoCAD or Civil 3D on Windows, because only the AutoLISP compiler inside the product can build one.

## 1. Check the sources (any machine)

```
python tools/check_lisp.py
```

The script checks parenthesis balance, unterminated strings, unprefixed function or global names, and leftover development notes. It does not run the code.

## 2. Test from source (Civil 3D)

1. Run `Install.cmd -AllowSource` from this folder. This installs the bundle with the `.lsp` sources instead of a VLX.
2. Start Civil 3D and open a drawing. The command line should show `C3DTools 1.0.0 loaded` and the note `loading development sources`.
3. Work through the smoke test in section 5.

## 3. Compile the VLX (Civil 3D)

1. Start Civil 3D and type `MAKELISPAPP`.
2. **Application location:** this repo's `C3DTools.bundle\Contents` folder. **Application name:** `C3DTools`.
3. **Application options:** leave **Separate Namespace** unchecked. The tools use per-drawing reactors and globals and are written for the document namespace. Check **ActiveX Support**.
4. **LISP files to include**, in this order:
   1. `src\C3DTools-Core.lsp`
   2. `src\C3DGuard.lsp`
   3. `src\C3DAudit.lsp`
   4. `src\C3DImpact.lsp`
5. **Resource files:** none. The dialog DCL is generated at run time.
6. **Compilation options:** Standard.
7. Finish. The wizard writes `C3DTools.vlx` and a `C3DTools.prv` make file. Commit the `.prv` so later builds can use *Rebuild from make file*. Do not commit the `.vlx`.
8. Uninstall the source test install (`Uninstall.cmd`), then install the VLX build with `Install.cmd` and repeat the smoke test.

## 4. Package

```
powershell -ExecutionPolicy Bypass -File build\Make-Release.ps1
```

This produces `dist\C3DTools-<version>.zip` with the bundle (loader, config, VLX, manifest), the installers and `README.md`. The sources are left out.

The publisher is set to Stephen Walz in `C3DTools.bundle\PackageContents.xml`. Bump `AppVersion` there, and `*c3dt:version*` in `src\C3DTools-Core.lsp`, for each release. Keep `UpgradeCode` the same across all releases.

## 5. Smoke test (each Civil 3D release you support)

| Check | Expected |
|---|---|
| `C3DTOOLS-STATUS` | Install and log folders shown. Civil 3D COM connected. |
| Type `MOVE` on an alignment | The normal MOVE runs and no Impact dialog appears (interception is off by default). |
| `C3D-IMPACT-INTERCEPT`, click Enable, then `MOVE` on an alignment | The impact dialog appears. Cancel blocks the move. |
| Close and reopen Civil 3D, then `C3D-IMPACT-STATUS` | Interception is still ON. Run `C3D-IMPACT-INTERCEPT` to turn it off. |
| Grip-drag an alignment | The impact dialog appears. |
| Run each surface edit command from the ribbon (Add Point, Delete Line, Swap Edge, and so on) | The impact dialog appears. |
| `EXPLODE` an alignment, then `U` | Guard alert appears and a row is added to `Events.csv`. |
| Save twice | `Health.csv` and `Civil3D_Audit_Report.csv` each have one current row for the drawing. The second save is not slower than the first. |
| Set `C3DTOOLS_LOGDIR`, restart | Logs go to the new folder. |
| `C3DGUARD-DUMPOBJECTS` against Toolspace | Counts match. |

## 6. Before listing publicly

- [ ] **Legal review of C3DAudit.** The trial version described itself as recreating an existing Power BI dashboard, built around specific project drawings. If that dashboard, its metric set or its column names belong to HDR (or any other employer or client), counsel needs to clear C3DAudit before it is listed. Removing that wording from the comments does not settle the question. Also confirm who owns the code in all four tools, given the employment and IP-assignment terms in force while it was written.
- [ ] Support contact and privacy statement for the store listing. The tools write drawing paths and names to local CSV files. They make no network calls.
- [ ] Disclose MOVE/STRETCH/ROTATE/SCALE interception in the listing text (see README).
- [ ] Smoke test passed on every Civil 3D release named in the listing.
