# Building and releasing ByLayerCheck

`src/ByLayerCheck.lsp` is compiled into `ByLayerCheck.vlx`. The VLX needs AutoCAD or Civil 3D on Windows, because only the AutoLISP compiler inside the product can build one. Until it is built, the source build below installs and runs the `.lsp` directly.

## 1. Check the source (any machine)

```
python tools/check_lisp.py
```

The script checks parenthesis balance, unterminated strings, unprefixed function or global names, and leftover development notes. It does not run the code.

## 2. Test from source (Civil 3D)

1. Run `Install.cmd -AllowSource` from this folder.
2. Start Civil 3D and open a saved drawing. The command line should show `loading source` and `ByLayerCheck 1.0.0 loaded`.
3. Work through the smoke test in section 5.

## 3. Compile the VLX (Civil 3D)

1. Start Civil 3D and type `MAKELISPAPP`.
2. **Application location:** this repo's `ByLayerCheck.bundle\Contents` folder. **Application name:** `ByLayerCheck`.
3. **Application options:** leave **Separate Namespace** unchecked. Check **ActiveX Support**.
4. **LISP files to include:** `src\ByLayerCheck.lsp`.
5. **Resource files:** none. **Compilation options:** Standard.
6. Finish. Commit the `.prv` make file so later builds can use *Rebuild from make file*. Do not commit the `.vlx`.
7. Uninstall the source install (`Uninstall.cmd`), install the VLX build with `Install.cmd` and repeat the smoke test.

## 4. Package

```
powershell -ExecutionPolicy Bypass -File build\Make-Release.ps1
```

This produces `dist\ByLayerCheck-<version>.zip` with the bundle (loader, config, VLX, manifest), the installers and `README.md`, without the source. Add `-SourceBuild` to package the `.lsp` instead of a VLX; its `Install.cmd` passes `-AllowSource`.

Bump `AppVersion` and `Version` in `ByLayerCheck.bundle\PackageContents.xml`, and `*blc:version*` in `src\ByLayerCheck.lsp`, for each release. Keep `UpgradeCode` the same across all releases.

## 5. Smoke test (each Civil 3D release you support)

| Check | Expected |
|---|---|
| `BLCHECK-STATUS` | Version, install folder and settings shown |
| Open a drawing where every object is ByLayer, with no xrefs | No dialog; results on the command line |
| Set one line's color to red, one to ByBlock, and one linetype to Dashed; save and reopen | Dialog shows color 2, linetype 1, either 3 |
| Put a red line inside a named block | Shown under Inside block definitions |
| Attach two xrefs, unload one, rename the other's file; reopen | Total 2, broken 1, unloaded 1 |
| Set `AlwaysShow` to `T`; open a clean drawing | Dialog appears |
| Set `CheckOnOpen` to `nil`; open a drawing | No check; `BLCHECK` still works |
| New drawing (Drawing1.dwg) | No check on open |
