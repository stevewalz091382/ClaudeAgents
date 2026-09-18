# Civil 3D Utility Network Clearance Clash Detection

`UtilityClashDetection.lsp` is an AutoLISP routine for Civil 3D 2027 that
proactively checks gravity and pressure pipe utility networks for
horizontal/vertical clearance conflicts, as they're being designed.

## Quick start

1. Copy `UtilityClashDetection.lsp` somewhere on your AutoCAD support file
   search path (or next to your `acaddoc.lsp`).
2. Load it once, either:
   - `(load "UtilityClashDetection.lsp")` from `acaddoc.lsp` (recommended -
     this makes the "prompt on file open" behavior work correctly for
     every drawing you open in the session, not just the first one), or
   - Add it to the Startup Suite (`Options > Files > Startup Suite`) if
     you typically only have one drawing open at a time.
3. Opening (or switching to) a drawing prompts:
   `Will you be designing gravity or pressure utility (pipe) networks in
   this drawing? [Yes/No]`
   Answer `Yes` and you'll be asked for 8 clearance values (horizontal and
   vertical, for gravity-gravity, pressure-pressure, gravity-pressure, and
   pipe-to-structure/fitting/appurtenance).
4. Run `UTILCLASHCHECK` any time to scan the drawing (or a selected work
   area) and flag every location where both the horizontal and vertical
   clearance fall short of your criteria.

## Commands

| Command | Purpose |
|---|---|
| `UTILCLASHSETUP` | Re-run the yes/no + criteria prompts manually |
| `UTILCLASHSETTINGS` | Jump straight to (re-)entering the 8 clearance values |
| `UTILCLASHCHECK` | Scan for conflicts and flag them in the drawing |

Clearance values are saved per-workstation (via `setenv`) so they carry
over as your default across drawings and sessions, and can always be
changed with `UTILCLASHSETTINGS`.

## How conflicts are flagged

Each conflict gets a text flag at the conflict location describing the two
parts involved and the actual vs. required horizontal/vertical clearance.
The routine first tries to create a real Civil 3D General Note Label
(`AECCADDGENERALNOTELABEL`); if that doesn't produce anything (depends on
your label style/template), it automatically falls back to a leader + text
flag on layer `C-UTIL-CLASH-FLAG`, which always works.

## Important limitations

Civil 3D does not expose a stable, public AutoLISP API for pipe/pressure
network parts (that surface is .NET-only). This routine works around that by:

- Identifying parts by entity class name (`AECC_PIPE`, `AECC_STRUCTURE`,
  `AECC_PRESSURE_PIPE`, `AECC_PRESSURE_FITTING`,
  `AECC_PRESSURE_APPURTENANCE`), with an automatic full-drawing scan
  fallback if none of those match.
- Reading geometry/diameter through several candidate COM property names,
  each wrapped in error handling, falling back to the part's 3D bounding
  box when none resolve. Any conflict involving bounding-box-approximated
  geometry is tagged `[APPROX GEOM]` in its flag text — verify those by hand.

If `UTILCLASHCHECK` reports 0 parts found in a drawing that clearly has
networks, select one part and run:

```
(vla-get-ObjectName (vlax-ename->vla-object (car (entsel))))
```

and add whatever name comes back to the appropriate `UC:*ClassNames` list
near the top of the `.lsp` file.

See the header comment in `UtilityClashDetection.lsp` for full details.
