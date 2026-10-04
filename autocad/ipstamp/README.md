# IPStamp and IPScan

AutoLISP tools for AutoCAD 2027 and Civil 3D 2027:

* **IPStamp** writes a "last touched" stamp onto each drawing object automatically. `vlr-object-reactors` trigger the writes. Right-click any object to see who created it, who last edited it, when, with which command, and in which drawing.
* **IPScan** scans drawings you receive from clients, contractors and subs, and reports where their content came from.

Both are pure AutoLISP and Visual LISP. They use no ARX, no .NET and no external programs.

| File | Purpose |
|---|---|
| `IPStamp-Core.lsp` | Shared engine: config, xdata, signatures, geometry fingerprint |
| `IPStamp.lsp` | Reactors, stamping, `IPWHO`, `IPMARK`, `IPXMIT`, right-click menu |
| `IPScan.lsp` | Inbound scanner: `IPSCAN`, `IPSCANFILE`, `IPSCANDIR` |

---

## Can the marks be made impossible to strip?

**No.** Nothing stored inside a DWG can be made impossible to remove. Whoever holds the file controls it. AutoCAD has no DRM for DWG: Autodesk removed DWG passwords and digital signatures in AutoCAD 2016. Civil 3D adds no protection on top.

What these tools do instead is make stripping **hard, and leave evidence when it happens**. The marks sit in five independent layers. Someone has to know about every layer, find it, and defeat it, and removing one layer is itself evidence.

| Layer | Where it lives | What it takes to defeat it | Survives |
|---|---|---|---|
| 1. Visible stamp | Xdata `IPSTAMP` on each object | One LISP routine. This layer is meant to be seen: it carries the IP notice, so nobody can claim they weren't told | Copy, paste, WBLOCK, save-as |
| 2. Hidden copy | Encrypted xrecord in each object's extension dictionary, under a neutral name you choose (`*IPS:ShadowKey*`). The drawing record has a copy in the named object dictionary | Knowing it exists, finding it under your name, and deleting it from every object. It can't be read or forged without your key. If layer 1 is stripped and this survives, the scan reports `[STRIPPED]`: proof the removal was deliberate | Same as layer 1, plus removal of layer 1 |
| 3. Coordinate watermark | Inside the geometry itself. `IPSEAL` moves each vertex of our polylines, lines, points, circles and block insertions by at most **0.000032 drawing units**, so that a residue set by your secret key is hidden in the digits | Suspecting it, then randomising or rounding every coordinate, or redrawing. There is no metadata to find | Stripping of all metadata, copy and paste, PASTEORIG, WBLOCK, DXF, explode, EXPORTTOAUTOCAD for plain objects, xbind |
| 4. Sentinels | Three invisible POINT entities in model space, watermarked and carrying layers 1 and 2 | Finding invisible objects (they can't be seen or window-selected) | Everything except deliberate removal |
| 5. Office manifests | A geometry fingerprint of every object we send, written by `IPXMIT` to a folder **in your office** (`*IPS:ManifestDir*`) | Changing the geometry itself. The recipient never has this file, so they can't strip it | Stripping of everything inside the file, as long as the geometry is unchanged |

Taken together: removing the visible stamp is caught by layer 2. Removing all metadata is caught by layers 3 and 5. To beat every layer, someone has to know the scheme, move every coordinate, and find the hidden objects. At that point they have effectively redrawn the design, which is copying anyway.

The strongest protection still sits outside the file:
* contract terms in sub and client agreements, with license, reuse and attribution clauses;
* sending PDFs or read-only views (Autodesk Docs/ACC permissions) where editable DWG isn't required;
* sending only the objects the recipient needs.

---

## 1. Install

1. Copy the three `.lsp` files to a shared CAD folder, for example `\\server\cad\lisp\ipstamp`.
2. In **OPTIONS → Files**, add that folder to **Support File Search Path** and **Trusted Locations**. SECURELOAD blocks loading otherwise.
3. Create the signing key file. This is a plain text file whose first line is a long random secret, for example `\\server\cad\secure\ipstamp.key`. Staff need read access to it. It must **never** go out with deliverables. Anyone holding this key can forge your stamps.
4. Add this to your office `acaddoc.lsp`. It runs once for every drawing opened:

```lisp
(setq *IPS:Org*      "Acme Civil Engineering Ltd"
      *IPS:IPNotice* "Proprietary design data of Acme Civil Engineering Ltd. Reuse, copying or derivation requires written permission."
      *IPS:KeyFile*  "\\\\server\\cad\\secure\\ipstamp.key"
      *IPS:LogMode*  "\\\\server\\cad\\logs\\ipstamp"          ; or "DWG" / "OFF"
      *IPS:RegisterFile* "\\\\server\\cad\\logs\\transmittals.csv"
      *IPS:ManifestDir*  "\\\\server\\cad\\secure\\manifests"  ; in-house only
      *IPS:ShadowKey*    "QX_7731")        ; your own neutral, unusual name
(load "IPStamp.lsp")
(load "IPScan.lsp")
```

Set the variables **before** the `load` lines. Every drawing then shows `IPStamp 1.0: watching N objects`.

> Every workstation must use the same `*IPS:Org*` text and the same key file. A stamp counts as "ours" only when both match.

---

## 2. Daily use: who touched this?

Select an object, right-click, and choose **IP Stamp - who touched this?**. You can also type `IPWHO`. Use `IPWHON` to inspect an object nested inside a block or an xref.

```
AeccDbAlignment   handle 3F2A   layer C-ROAD-ALGN
Name: Main St CL

LAST TOUCHED
  ACME\jsmith  on WS-0142
  2026-10-03 14:22:05  (Eastern Standard Time)
  command GRIP_STRETCH  in Site-Plan.dwg

ORIGIN
  Owner:   Acme Civil Engineering Ltd
  Created: 2026-03-02 09:10:44  by ACME\mlee on WS-0107
  Drawing: Base-Alignments.dwg
  DWG id:  {8C1E...}
  How:     NATIVE

EDITS RECORDED: 14
HISTORY (newest first)
  2026-10-03 14:22:05 ACME\jsmith GRIP_STRETCH @Site-Plan.dwg
  2026-09-28 10:02:11 ACME\akhan MOVE @Site-Plan.dwg
  ...
INTEGRITY
  Origin signature: VALID (signed with our key)
  Record signature: VALID (signed with our key)
  Geometry: matches the last stamp
IP: Proprietary design data of Acme ...
```

### What each object carries (xdata app `IPSTAMP`)

| Key | Meaning |
|---|---|
| `ORG`, `IP` | Owning organisation and the IP notice |
| `C_USER` `C_HOST` `C_TIME` `C_DWG` `C_DWGID` | Origin: who created the object, on which PC, when, and in which drawing (`DWGID` = the drawing's `FINGERPRINTGUID`, which survives SaveAs copies) |
| `C_TYPE` | How the object arrived: `NATIVE`, `INSERTED:<cmd>`, `IMPORTED:<cmd>` (paste, xbind, import), `DERIVED:<cmd>` (explode), `AUTO`, `PRE-EXISTING`, `BASELINE` |
| `C_KEYID` `C_SIG` | Origin signature. Written once and never rewritten, even when another office edits the object |
| `M_USER` `M_HOST` `M_TIME` `M_CMD` `M_DWG` | Last edit made through a command |
| `A_USER` `A_TIME` `A_DWG` | Last change made with no command running: Properties palette edits, Civil 3D rebuilds, data-shortcut sync |
| `N`, `H` | Number of recorded edits, and the last 5 edits (`*IPS:HistoryDepth*`) |
| `GEO` | Geometry fingerprint at the last tracked edit |
| `TZ` | Windows time zone of the last writer |
| `KEYID` `SIG` | Signature over the whole record |

Erased objects can't hold xdata, so they go to the CSV edit log. By default the log sits next to the drawing as `<name>_ipstamp.csv`.

---

## 3. Before you send files out

Run `IPXMIT` and answer **Yes** to "Mark and seal". It does all of the following in one go:

1. `IPMARK` claims every unstamped object in the drawing for your organisation (`C_TYPE = BASELINE`). It also writes a signed ownership record into the drawing's named object dictionary and fills **DWGPROPS → Custom** with `IP_OWNER`, `IP_NOTICE`, `IP_DWGID` and `IP_MARKED`. It leaves pasted, imported and third-party content **unclaimed**, and reports how many objects it skipped so you can review them.
2. `IPSEAL` watermarks the coordinates of every object you own, refreshes its visible stamp and hidden copy, and places the hidden sentinels. It never touches content that isn't yours. You can also run it on its own.
3. `IPXMIT` writes the geometry manifest to your in-house folder and records the transmittal inside the drawing (recipient, purpose, who, when) and optionally appends a row to the office register CSV. It can run `IPMARK` first.
4. **Save.** The marks travel inside the DWG.

> Edits after sealing keep layers 1 and 2 current automatically. The watermark on any vertex you move is refreshed only the next time you seal, and `IPXMIT` always seals.

When the file comes back, or when your content turns up in someone else's drawing, IPScan reads those marks.

---

## 4. Files you receive: IPScan

| Command | Scans |
|---|---|
| `IPSCAN` | The current drawing, including FINGERPRINTGUID, create date and total editing time |
| `IPSCANFILE` | One received DWG, opened read-only through ObjectDBX |
| `IPSCANDIR` | Every DWG in a folder, with subfolders optional. Use it on a whole incoming package |

The output goes to `My Documents\IPScan` (or `*IPS:ReportDir*`) and the report opens in Notepad:

* `IPScan_<time>.txt`: the readable report, one section per file
* `IPScan_<time>_files.csv`: one row per file, ready for the project's incoming register
* `IPScan_<time>_objects.csv`: one row per stamped object

### Reading the verdict

| Tag | Meaning |
|---|---|
| `[STRIPPED]` | The visible stamp, or the drawing record, was removed, but the hidden copy survived and proves origin. Strong evidence of deliberate removal |
| `[WATERMARK]` | Our coordinate watermark was found. `VERIFIED` means z ≥ 8: odds of coincidence are effectively zero. `PROBABLE` means z ≥ 4, usually because the content was partly edited |
| `[SENTINEL]` | Hidden sentinel points from our drawings are present |
| `[MANIFEST]` | Objects geometrically identical to ones we sent, naming the package, date and recipient |
| `[HIDDEN]` | Hidden copies that can't be read with our key: another firm's, or written with a retired key |
| `[OUR IP]` | Objects whose origin signature verifies with our key. Our design content is in this file |
| `[ALERT]` | The object claims our organisation but fails the signature check, carries a different key, or has a hand-edited record. Someone altered or forged a mark |
| `[CHANGED]` | Our objects whose geometry changed after their last tracked edit, which means outside our office |
| `[OTHERS]` | Stamps from other organisations, or unclaimed or imported content |
| `[CLAIM]` | The drawing-level ownership record from `IPMARK`, with its signature check |
| `[TRACE]` | Transmittals we recorded with `IPXMIT`: this file left our office |
| `[UNKNOWN]` | Objects with no stamp. Their origin must be judged from the evidence sections |
| `[SOFTWARE]` | Applications that left traces in the file: Civil 3D, Map 3D, MicroStation/DGN, Revit, BricsCAD, ODA-based writers, and others |
| `[PROXY]` | Objects created by an application not loaded on your machine |

For unmarked files, the evidence sections list:

* DWGPROPS and custom properties, including Author and LastSavedBy
* non-standard registered applications and named dictionaries
* xref and image paths, which often name the sender's server and project number
* layer-name prefixes (an office standards fingerprint)
* fonts, layouts and paper-space title-block attribute values
* object type counts

Add the patterns you see from known senders to `*IPS:Signatures*` in `IPScan.lsp`.

---

## 5. How it works

```
 object modified ──► :vlr-modified (object reactor) ──► queue (object, time, command)
 object created  ──► :vlr-objectAppended (db reactor) ─► queue (ename, time, command)
 object erased   ──► :vlr-erased   (object reactor) ──► queue (handle, its stamp)
                                                             │
   :vlr-commandEnded / :vlr-lispEnded / :vlr-beginSave ◄─────┘
                                  │
                     write IPSTAMP xdata (one undo group)
                     add new objects to the object reactor
                     append rows to the CSV edit log
```

* AutoCAD does not allow an object to be changed inside its own `:vlr-modified` callback. The callback therefore only queues the object, and the write happens when the command ends. Nested and transparent commands are counted, so the queue is flushed only when the outermost command finishes.
* The time and command are captured when the change happens, not when the write happens.
* `U`, `UNDO`, `MREDO` and the save and close commands are never stamped. Neither are the tool's own writes.
* If the object sits on a locked layer, which happens with Civil 3D dependent rebuilds, the layer is unlocked for the write and then locked again.
* The reactors are transient. `acaddoc.lsp` attaches them again in every drawing session, so no persistent reactor is left in files you send out.

---

## 6. Configuration

Set these before loading. Defaults are in `IPStamp-Core.lsp` and `IPStamp.lsp`.

| Variable | Default | Notes |
|---|---|---|
| `*IPS:Org*` | `"YOUR COMPANY"` | Must be identical on every workstation |
| `*IPS:IPNotice*` | generic notice | Written into every object we originate |
| `*IPS:KeyFile*` | `""` (default key) | **Set this.** With the default key, the signatures prove nothing |
| `*IPS:Types*` | Civil 3D `AECC_*`, blocks, linework, text, dims, hatches... | A wcmatch pattern on DXF type. Narrow it for drawings with very many objects, for example by dropping `TEXT,MTEXT` or using specific `AECC_ALIGNMENT,AECC_PROFILE,...` types instead of `AECC_*` (which includes every COGO point and label) |
| `*IPS:HistoryDepth*` | `5` | History entries kept per object |
| `*IPS:LogMode*` | `"DWG"` | `"DWG"`, `"OFF"`, or a folder path |
| `*IPS:RegisterFile*` | `""` | Transmittal register CSV for `IPXMIT` |
| `*IPS:ReportDir*` | `""` | IPScan output folder |
| `*IPS:ImportCmds*`, `*IPS:DeriveCmds*`, `*IPS:InsertCmds*` | see core | Command patterns used to label how objects arrived |
| `*IPS:IgnoreCmds*` | `U,UNDO,MREDO,QSAVE,...` | Commands whose changes are never stamped |
| `*IPS:AutoMenu*` | `"YES"` | Add the right-click entry on load |
| `*IPS:Shadow*` | `"YES"` | Write the hidden encrypted copy (layer 2) |
| `*IPS:ShadowKey*` | `"QC_REF"` | **Change this** to a neutral, unusual name of your own. It is the name a stripper would have to know |
| `*IPS:WMTypes*` | `LWPOLYLINE,POLYLINE,LINE,POINT,CIRCLE,INSERT` | Types `IPSEAL` watermarks. Add `AECC_COGO_POINT` only if your survey standards accept the shift. Arcs are left out because moving an arc's centre would open tiny gaps at its ends |
| `*IPS:WMStep*`, `*IPS:WMBins*` | `1e-6`, `32` | Maximum shift = step × bins = 0.000032 units |
| `*IPS:ManifestDir*` | `""` (off) | In-house folder for geometry manifests. **Set this.** Never send it out |
| `*IPS:ChainUndo*` | `"NO"` | See the undo test below |

`IPSEAL` runs `IPMARK`, then watermarks and seals the drawing. Other commands: `IPSTATUS` shows tracking state, key id and log path. `IPSTAMPOFF` and `IPSTAMPON` suspend and resume tracking. `IPMENU` and `IPMENUREMOVE` add and remove the right-click entry.

**If the right-click entry doesn't appear**, the edit-mode menu in your CUIx has a different name. Open `CUI`, create a command named *IP Stamp - who touched this?* with the macro `_IPWHO `, and drag it into **Shortcut Menus → Edit Menu**. AutoCAD merges that menu into every object's right-click menu, including alignments and profiles.

---

## 7. First-run test (do this once on a test drawing)

These tools haven't been run inside AutoCAD yet. They were syntax-checked offline only. Before rolling them out, run them once on a copy of a real project drawing:

1. Load the tools and check that `IPSTATUS` shows your org, your key id (not the default key) and a log path.
2. Draw a line, then run `IPWHO` on it. It should show `How: NATIVE` with you as creator.
3. `MOVE` the line, then run `IPWHO`. It should show `command MOVE` and `EDITS RECORDED: 2`.
4. Grip-edit a Civil 3D alignment, then run `IPWHO`. It should show `GRIP_STRETCH`, and its profile and labels should show the same edit.
5. **Undo test.** Move the line, then press `U` once.
   * If the line moves back, everything is right. Leave `*IPS:ChainUndo*` at `"NO"`.
   * If the line stays put and only the stamp is undone, set `*IPS:ChainUndo* "YES"`. A second `U` will then be issued for you.
6. Copy an object into a second drawing with `COPYCLIP` and `PASTECLIP`, then run `IPWHO` on the copy. The origin should still name the first drawing, and the history should show `PASTECLIP`.
7. Run `IPMARK`, save, close, then run `IPSCANFILE` on that file. It should report `[OUR IP]` and `[CLAIM] ... VALID`.
8. Open the file on a PC **without** IPStamp loaded and move an object. Then run `IPSCANFILE` again from your PC. That object should be reported as `[CHANGED]`.
9. **Strip test.** Run `IPXMIT` on a test drawing, with `*IPS:ManifestDir*` set, and save. On a PC without the tools, strip the visible stamps with this one-liner:
   `(vlax-for o (vla-get-modelspace (vla-get-activedocument (vlax-get-acad-object))) (vla-setxdata o (vlax-safearray-fill (vlax-make-safearray 2 '(0 . 0)) '(1001)) (vlax-safearray-fill (vlax-make-safearray 12 '(0 . 0)) '("IPSTAMP"))))`
   Save, then `IPSCANFILE` it from your PC. Expect `[STRIPPED]`, `[WATERMARK] VERIFIED`, `[SENTINEL]` and `[MANIFEST]`. Open it with IPStamp loaded and edit an object: the visible stamp comes back from the hidden copy.
10. Run `IPWHO` on a sealed polyline. The **HIDDEN LAYERS** section should say "hidden copy present" and "N of N coordinates carry our mark (sealed)".

---

## 8. Limits (read before relying on this for a dispute)

* **Nothing in a DWG is unstrippable.** See "Can the marks be made impossible to strip?" above. Each layer can be defeated by someone who knows it exists. The design goal is that defeating all of them takes real knowledge and effort, and that partial removal leaves evidence.
* **What defeats the watermark:** moving, rotating or scaling the geometry; rounding coordinates (for example, a LandXML export at low precision); redrawing; converting Civil 3D objects with `EXPORTTOAUTOCAD`. Alignments, profiles and corridors are not watermarked directly, because editing their geometry through COM is too risky. Polylines you build them from are watermarked, and the alignments carry layers 1, 2 and 5. A sub who rebuilds an alignment from our watermarked polyline carries our watermark into it.
* **Joins:** identical coordinates always get identical watermarks, so snapped endpoints stay joined. A line ending on the **middle** of another segment (a T-junction) can end up as much as 0.000032 units off that segment. Check that tolerance against your standards before you seal survey or construction data.
* **The signature and the encryption are tamper evidence and obfuscation, not cryptography.** They are a keyed 64-bit hash and a keyed stream cipher written in pure AutoLISP, which has no SHA, HMAC or AES. They stop forgery and reading by anyone without your key file. They won't stop a well-funded expert attack. Guard the key file. If it leaks, issue a new key: old marks then report as `signed with a different key`.
* **Keep the scheme confidential.** Layers 2 to 4 rely partly on recipients not knowing they exist. Don't send these LSP files or this README to clients or subs, and use your own `*IPS:ShadowKey*` name.
* **The geometry fingerprint** uses rounded properties and the bounding box. It flags changes reliably, but a `CHANGED` result means "check this", not "proven altered". Text-like objects use their properties only, because their bounding box depends on fonts.
* **Time** is the workstation clock in the zone recorded in `TZ`. Users can change PC clocks. The central CSV log on a server (`*IPS:LogMode*` set to a folder) gives you a second, independent record.
* **Pre-existing objects** in drawings you open for the first time are stamped `PRE-EXISTING` and `(unclaimed)` when someone first edits them. IPStamp records where it first saw them, not who made them. Only `IPMARK` claims them.
* IPStamp **records**. It does not prevent copying. Use it alongside your contracts, transmittal records, and the IP clauses in your sub agreements. For a formal dispute, get legal advice on how to present these records as evidence.
