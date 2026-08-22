# TEST_REPORT.md — Resource Optimization Engine (ROE)

## RE-TEST pass ROUND 3 — final independent verification of the header-verification fix (`2c67784`) — 2026-08-22

Under test: `index.html` at commit `2c67784` ("Fix custom-fields column matching: header-verify
instead of blind position, per Manager's own recommended hybrid approach"), against the Manager's
`MANAGER_REVIEW.md` ADDENDUM 1 findings (issues 1-3: invalid-Number-cell erasure, positional-zip
misassignment in three variants — inserted column / reordered `CustomFieldDefs` rows / stolen-by-
fuzzy-match canonical column — and rejected-def-row cascade). Coder's claim: `readCustom` now verifies
header text at each zipped position against `def.label` before assigning, reports a clear error and
leaves the existing value untouched on mismatch; `presentKeys` only set on genuine-blank-or-parsed,
never on parse failure; `detectMapping` reserves position+header-matched custom columns before fuzzy
canonical matching runs; a rejected `CustomFieldDefs` row no longer cascades; added a key-hint next to
custom field labels in edit forms. Claims all 5 Manager findings fixed, ported MGR-A..G into
`tests/specs/mgr-workbook-io-fix-round2.spec.js`, 152/152 full suite.

**Result: the 5 findings the fix explicitly targeted are genuinely closed, confirmed both by the
Coder's own ported probes and by re-running them myself. But the header-verification mechanism itself
has a new gap the Manager's 7 probes never exercised: it compares header text with strict `===`
(byte-exact) equality instead of the same normalized comparison (`U.normalizeHeader`: lowercase, strip
non-alphanumerics) that canonical-column matching already uses elsewhere in this same function chain.
A custom column header that differs from the stored `def.label` by case only — a completely mundane
Excel-editing outcome, not a contrived edge case — is treated as "column not found for this def" rather
than "this is the same column, differently cased." Combined with a deleted canonical column that the
mangled header now fuzzy-resembles (the exact MGR-E scenario), this reopens the identical bug class the
fix was written to close: the canonical field is silently overwritten with the custom column's value,
the custom value itself is silently dropped, and zero errors are reported. This is a genuine, clean,
independently-reproduced regression-of-the-fix, not a manufactured finding — see CRITICAL/HIGH #1
below. Two secondary, lower-severity gaps (spurious-but-safe mismatch errors on whitespace-padded
headers; asymmetric strictness vs. canonical matching) round out the round. Isolation, blank-vs-absent,
and full-UI-path "existing value untouched" claims all held up under attack.**

**What I ran:**

1. Fresh full committed suite myself, from a clean `cd tests && npx playwright test
   --config=pw.local.config.js`: **152 passed, 0 failed** (~2.1 min), matching the Coder's claim
   exactly. Confirmed console output for every persistence/session-only/API/perf/custom-fields spec
   name individually (not just the pass count) — e.g. `MGR-C-repro`, `MGR-A2-repro`,
   `repro#1 fresh result`, `unsupported-entity-type result` all printed the expected values.
2. Re-ran `tests/specs/mgr-workbook-io-fix-round2.spec.js` **unmodified**, isolated: **7 passed, 0
   failed** (MGR-A, D, E, C, B, F-control, G-control), console output showing the exact clear error
   text now produced for each structural edit (e.g. `"Expected custom column 'Region' but found
   'Reviewed By' at that position..."`) and the previously-stored value surviving each attack
   (`storedCustomAfterReimport` unchanged in every case). All 7 of the Manager's own probes hold.
3. Spot-checked prior-round regressions by name in the same full run: `persistence.spec.js` (all 12,
   including the session-only reload-gate and token-redaction checks), `tester-round3-independent.spec.js`
   (all 7 MGR-repro a/a2/b/c + regression checks), `custom-fields-addendum.spec.js`,
   `workbook-io.spec.js`, `settings-validation.spec.js` — all green, all base-app fix-loop work and the
   addendum's first fix round remain unaffected by this commit.
4. Wrote a fresh probe set (scratchpad-only, not committed — `tester-round2-probe*.spec.js`, run via
   the project's own `pw.local.config.js` then removed; `git status` confirms `tests/specs/` is clean)
   attacking exactly the angles requested: header case/whitespace vs. exact match, more-leftover-than-
   defs, fewer-leftover-than-defs (column entirely absent vs. present-but-blank), error isolation across
   fields in one row, and the full `handleImportFile → previewImport → applyImport` UI path (not just
   direct `STORE.upsert` calls) for the "existing value untouched" claim.
5. Re-checked CDN reachability: `curl` to both `cdn.jsdelivr.net/npm/chart.js` and the jsDelivr-hosted
   SheetJS build still returns `CONNECT tunnel failed, response 403` from this shell — unchanged,
   still a known declared environment gap (VERIFY-1), not a new finding.

**Findings:**

### 1. HIGH — header verification uses byte-exact string equality instead of the app's own normalized comparison, so a case-only (or whitespace-only) difference in a custom column's header text reopens the exact MGR-E "fuzzy match steals a custom column" corruption the fix exists to close — silently, with zero errors, for a brand-new record

`readCustom`'s mismatch check (`index.html:1743`) is `String(headerText) !== String(def.label)` — raw,
case-sensitive, whitespace-sensitive. `detectMapping`'s custom-column reservation (`:1635`) uses the
identical strict check. But canonical-column matching two lines above it (`:1619`) uses
`U.normalizeHeader(h) === U.normalizeHeader(f)` — lowercase, non-alphanumeric-stripped — specifically
*so that* trivial header variations don't break matching. The new custom-field code is inconsistently
stricter than the canonical code sitting right next to it in the same function.

Reproduced cleanly (isolated in the scratchpad, not the committed suite — see repro steps below): add
an Employee custom field labeled "Office Location" (text). Export. In the exported sheet, delete the
canonical "Office" column entirely (an ordinary edit — arguably *more* likely than inserting a
column, since a planner might consider "Office" redundant once "Office Location" exists) and change
only the case of "Office Location"'s header cell to "office location" (equally ordinary — Excel
autocapitalization, a copy-pasted template header, or someone just retyping it). Import a **brand-new**
row (never previously stored, so no merge-preserve fallback from an existing record can mask the
outcome) with that column's cell = `"Denver"`.

Result: `detectMapping` cannot reserve "office location" for the custom def (strict-equality fails), so
it falls into the fuzzy-candidate pool; `fuzzyMatchHeader("Office", ["office location"])` scores 60
(substring match) and wins, since "Office" has no exact-match column left. `mapping.Office = "office
location"`. `readCustom` then marks that same column index as claimed *by the canonical field* before
it ever looks at `customDefs`, so the custom def's leftover-column search finds nothing at that
position — not a mismatch (which would report an error), but "no column present for this def at all"
(which reports nothing, by design, since a genuinely-absent column is meant to be silent). Net result:

- `errors`: `[]` — zero errors reported.
- Canonical `employee.office` = `"Denver"` — silently overwritten with the *custom* column's raw text.
- `employee.custom` — the `office_location` key is **entirely absent** (not blank, not present-and-
  cleared — just never written), so the value the user typed for "Office Location" is gone.

This is not "a mismatch reported that the user has to notice" (the acceptable outcome for the fix's
other scenarios) — it is complete silent data loss plus cross-field corruption, identical in shape to
the original MGR-E finding this exact commit's own inline comment (`:1606-1611`) says it closes. The
fix only holds when the file's header text is byte-identical to the stored `def.label`; it was framed
(by the Coder's comment and the Manager's review) as closing the class of "any structural edit to an
exported sheet," but a structural edit was never required here — only a one-character casing change to
a header cell alongside an unrelated canonical-column deletion, both entirely plausible independently
in the same hand-edit session.

Why HIGH and not (only) MEDIUM like the original collective finding: the Manager rated the original
three-variant issue MEDIUM in part *because* "canonical columns are unaffected" by two of the three
variants. Here the canonical column (`Office`) is directly and silently corrupted, not merely
unmapped — this is strictly worse than the MGR-E variant it reopens.

Reproduce: `STORE.addFieldDef("Employee","Office Location","text")`; build the export via
`IO.buildWorkbookSheets`; take the emitted header/row, delete the "Office" column entirely, and replace
the "Office Location" header cell with `"office location"` (lowercase); construct one new data row with
`EmployeeID`/`Name`/enum fields filled to pass validation and the custom column's cell = `"Denver"`;
run the file's own `CustomFieldDefs` sheet through `IO.parseCustomFieldDefsSheet` →
`IO.customDefsFor` → `IO.detectMapping` (mirroring `handleImportFile`) to get the real mapping; feed
into `IO.parseWorkbook`; inspect the resulting record's `office` and `custom` fields directly (`errors`
array is empty, `office` is `"Denver"`, `custom` has no `office_location` key at all).

Fix shape: the mismatch check at `:1743` (and the reservation check at `:1635`) should use
`U.normalizeHeader` for the comparison, exactly like the canonical-matching code three lines above it
already does — consistent, not stricter-for-no-reason. That alone would make this case round-trip
correctly (as a match, not a mismatch, not a theft).

### 2. LOW — a harmless whitespace-padded header (no canonical column involved) produces a spurious "column mismatch" error instead of matching, unlike canonical columns which tolerate it

Same root cause as #1, isolated without the fuzzy-theft compounding factor: export a file with a
"Region" custom text field, then pad the header cell to `" Region "` (a realistic artifact of copying
a header from a merged/formatted Excel cell) without touching any canonical column. Result: `readCustom`
reports `"Expected custom column 'Region' but found ' Region ' at that position"` and does not update
the value (existing value survives — no corruption, just a false-positive error and a value that
silently fails to update from the file even though the column is unambiguously present). A canonical
column with the same whitespace variance would match fine via `U.normalizeHeader`. Not data-destructive
on its own (the existing value is preserved, per the "leave alone on mismatch" design), so this is a
UX/consistency gap rather than corruption — same one-line fix as #1 would close it too.

### 3. Confirmed correct (no new finding) — several angles specifically requested, verified clean:

- **More leftover columns than defs** (an extra hand-added junk column with no corresponding def at
  all, trailing after the real custom column): ignored cleanly, zero errors, existing custom value
  round-trips correctly. The zip only ever consumes as many leftover columns as there are defs; extra
  columns are never touched.
- **Fewer leftover columns than defs, distinct from a present-but-blank cell** (a def's column deleted
  from the sheet entirely, with a second custom column still present after it): the deleted def's key
  never appears in `presentKeys` (no error, no value) and — via `STORE.upsert`'s merge — the previously
  stored value for that key survives untouched on re-import, correctly distinguished from a genuinely
  blank cell (which does clear it, per the "MGR-C" design). Confirmed with two custom fields
  simultaneously (one column removed, one intact) to make sure the removal of one didn't shift the
  other — it didn't.
- **Error isolation within one row**: forcing both custom fields in a row to mismatch (via a single
  inserted column shifting everything after it) produces two independent per-field errors, and does
  not block that same row's canonical fields (`Office`, `Notes`) from importing their own new values
  correctly. Confirmed against `mgr-workbook-io-fix-round2.spec.js`'s own MGR-B result too (Team
  mismatch does not prevent Badge's own error/value handling, and vice versa).
- **Full UI-path "existing value untouched" claim**: re-verified end-to-end through
  `handleImportFile`'s own mapping-detection step (using the file's own `CustomFieldDefs` sheet, not
  local defs, exactly as production code does) → `previewImport` → `applyImport`'s exact sequence
  (`restoreFieldDefs` then `STORE.upsert`), not just a direct `STORE.upsert(parseSheet(...))` shortcut.
  The pre-set value survived byte-for-byte through the real pipeline on a header-mismatch attack.
- **Duplicate-label key hint**: `customFieldInputsHtml` (`:3333`) now renders
  `<label>Label <span class="hint">(type, key: the_key)</span>...` for every custom input — confirmed
  by reading the code, closing the Manager's §2 UX gap for duplicate-labelled fields in manual forms.

**CDN reachability**: unchanged. `curl` to `cdn.jsdelivr.net/npm/chart.js` and the jsDelivr-hosted
SheetJS build both still return `CONNECT tunnel failed, response 403` in this shell. `index.html:8-9`
is unchanged. Still VERIFY-1, still a known, honestly-declared environment gap, not a new finding.

**Verdict on the addendum, including workbook-IO robustness: not quite done yet.** The four issues the
Manager named (invalid-Number-cell erasure, inserted-column misassignment, reordered-defs-sheet swap,
rejected-def-row cascade) plus the fifth (fuzzy-theft-on-byte-identical-headers) are genuinely,
independently confirmed closed — three fix rounds on this narrow area were not wasted. But the fix's
own header-verification mechanism introduces exactly one new gap of the same severity class it was
built to close, triggered by a completely ordinary real-world variation (header casing) that the
Manager's 7 probes never had reason to try because all of them used byte-identical, app-generated
label text for the "still matches" side of every comparison. One line (normalize both sides of the
`:1743`/`:1635` comparisons the same way `:1619` already does) would close it. I recommend one more
narrow fix-and-verify pass on this specific point before calling the addendum fully done; I would not
block sign-off on the LOW (#2) alone.

---


## RE-TEST pass ROUND 2 — verification of the Coder's custom-fields workbook-IO fix (`3452c8d`) — 2026-08-22

Under test: `index.html` at commit `3452c8d` ("Fix custom-fields workbook-IO bugs: match by key/position,
not label"), against my own prior CRITICAL + 2×HIGH + MEDIUM findings from the ADDENDUM 1 pass below
(`754c74a`/`5ad8974`). Coder's claim: replaced label-text `indexOf()` column matching with
position-based matching against the file's own `CustomFieldDefs` sheet order, added an
`__importedCustomKeys` marker so `STORE.upsert()` can merge (not fully replace) `custom` on re-import,
and added an "Unknown skill (ID)" fallback in the Skills Matrix and the Demand editor. Claimed: my own
`adversarial-custom-fields-addendum.spec.js` now 8/8 (was 4/8), full suite 137/137.

**Result: the fix holds. All 4 original findings (1 CRITICAL, 2 HIGH, 1 MEDIUM) are confirmed closed
by independent re-testing, not just by re-running the Coder's or my own prior spec unmodified. I found
one new, minor (LOW) gap while doing a fresh adversarial pass on top of the fix, unrelated to the 4
original findings and not a regression introduced by this commit's diff. I did not find any CRITICAL or
HIGH issue this round.**

**What I ran:**

1. The full committed suite fresh, myself, from a clean `cd tests && npx playwright test
   --config=pw.local.config.js` (same uncommitted local Chromium-path override as every prior round —
   the committed `tests/playwright.config.js` still cannot launch a browser in this sandbox, unchanged
   across all rounds): **137 passed, 0 failed** (~2.1 min) on the first run, confirming the Coder's
   129/129 + my own 8/8 `adversarial-custom-fields-addendum.spec.js` claim exactly.
2. Re-ran `tests/specs/adversarial-custom-fields-addendum.spec.js` **unmodified**, isolated, on its
   own: **8 passed, 0 failed** — including all 4 tests that were failing last round (dual-label
   round-trip, canonical-"Name"-collision round-trip, re-import silent-erasure, "Unknown skill"
   rendering) and all 4 that were already passing (repopulate-on-redef, true v1→v2 migration,
   deterministic capacity-overage warning, XSS-in-label). Confirmed with real values in the console
   output, not just green checkmarks: e.g. `reparsedCustom:{"region":"East","region_2":"West"}` (was
   both `"East"` before), `customValueAfterReparse:"CUSTOM_FIELD_VALUE"` (was misreading the canonical
   "Real Employee Name" before), `customAfter:{"badge_number":555}` surviving a re-import that omits
   the column (was `undefined` before), `'Unknown skill' text ever rendered in UI: true` (was `false`
   before).
3. Wrote a **brand-new** spec, `tests/specs/tester-round2-recheck.spec.js` (8 tests), deliberately not
   copy-pasted from my own prior adversarial file, to independently re-attempt each of the 4 original
   repros from scratch with different data/mechanics than either my own or the Coder's existing specs
   use, plus one new adversarial angle the task specifically asked for. All 8 passed after one
   self-correction (see note below):
   - **Repro #1 (CRITICAL) re-attempted with a twist my own original spec didn't cover**: two custom
     defs on the same employee, but the re-imported file's own `CustomFieldDefs` sheet + entity sheet
     only mention **one** of the two fields (a genuinely self-consistent "older export taken after
     field A existed but before field B was added" shape, not just "no custom columns at all"). Result:
     the mentioned field (`badge_number`) correctly **updates** to the new value (`777`), and the
     unmentioned field (`home_office`) is **left completely untouched** (`"Denver"` survives). A second
     test confirms the complementary case: a column that **is** present in the file with a **blank**
     cell is treated as an explicit clear (value becomes absent), correctly distinct from "column not
     in the file at all." Both passed. (Self-correction: my first draft of this test omitted a
     `CustomFieldDefs` sheet from the hand-built AoA entirely, which — correctly, per IO-1's own
     backward-compatibility design — causes the parser to skip reading *any* custom columns for that
     import, since a file with no `CustomFieldDefs` sheet is defined as "no custom values". That was a
     bug in my test's setup, not in the app; I fixed the test to include a self-consistent
     `CustomFieldDefs` sheet declaring only the field that should be "mentioned," then it passed.
     Documented here in the interest of showing my work, not hiding a false start.)
   - **Repro #2 (HIGH) re-attempted via the real Manage Fields UI** (clicking `#btn-manage-emp-fields`
     → `#mf-label` → `#mf-add` twice with the identical label "Territory"), not `STORE.addFieldDef()`
     called directly as before. Set `North`/`South` on the two auto-suffixed keys, built and re-parsed
     the workbook. Both values came back correctly matched to their own key (`north`/`south`), not
     swapped or collapsed. **Passed.**
   - **Repro #3 (HIGH) re-attempted with the Number-typed variant explicitly**, which the original
     finding's write-up called out as a "secondary, less severe symptom" (a spurious "'Notes' must be a
     number" validation error on a perfectly valid row, caused by the old code misreading the canonical
     free-text `Notes` column as the numeric custom field). Added an Employee custom field literally
     labeled "Notes", type Number, alongside the real canonical `Notes` field. Round-tripped: canonical
     `notes` stays as the free-text string, the custom field stays as its own distinct number
     (`12345`), and — confirming the secondary symptom is *also* fixed as a side effect of the same
     position-based rewrite — **zero** validation errors are produced (was 1 confusing, wrong-column
     error before). **Passed**, and this closes a part of finding #3 my original write-up flagged but
     didn't have a dedicated assertion for.
   - **Repro #4 (MEDIUM) re-attempted against a `Demand.requiredSkills` reference specifically**, not
     an `EmployeeSkill` reference (the original finding's repro and the Coder's own diff both mention
     the Demand editor as a *separate* code path from the Skills Matrix — `resolvedRequiredSkillsLabel`
     vs. the matrix's orphan-column logic — so this needed its own, separate confirmation). Assigned a
     demand's `requiredSkills` to reference a real skill, confirmed the Demand editor shows the real
     skill's name (not "Unknown skill") beforehand, then deleted that skill via the real UI confirm
     dialog, reopened the same project's demand editor, and confirmed the "Resolved:" hint now
     literally contains the string `"Unknown skill"` plus the dangling skill ID, and that
     `demand.requiredSkills` itself is untouched (length still 1, no crash, no cascade-delete).
     **Passed** — the fallback genuinely renders in the *second* place the addendum promised it, not
     just the Skills Matrix.
   - **New adversarial angle (per this round's task): a `CustomFieldDefs` sheet entry for an entity
     type this app's current field defs don't represent at all.** I tested both readings of that
     phrase to be thorough:
     - *A def for a key genuinely never seen locally before* (a colleague's export, or a file from a
       different browser profile, defining `Employee/cost_center` when the current local instance has
       zero custom field defs at all) — per IO-1's literal text ("recreate any defs missing locally").
       Confirmed: `parsed.fieldDefs.toAdd` contains it, `STORE.restoreFieldDefs()` recreates the def
       with the exact same key/label/type, and the corresponding column's value (`"CC-9001"`) round-trips
       correctly into `record.custom`. **Correct, IO-1 holds for this case.**
     - *A def whose `EntityType` string isn't among the app's 6 recognized types at all* (`"Vendor"`,
       simulating a hand-edited or much-older/foreign file) — confirmed this is rejected as a per-row
       `CustomFieldDefs` error (`"Unknown entity type 'Vendor'"`), **never crashes** (0 `pageerror`
       events), **never silently invents** a phantom `Vendor` def, and — importantly — **does not
       poison the rest of the sheet**: a second, valid row in the very same `CustomFieldDefs` sheet
       (`Employee/legit_field`) still gets created and its value still round-trips correctly
       (`"OK"`). This is correct, defensible, non-destructive behavior for genuinely invalid/foreign
       data — not a bug, and not something the plan's "never delete a local def" language was ever
       trying to cover (there's no local def in play here at all; it's rejecting an invalid *new*
       entry, which is different from deleting an *existing* one).
   - **While probing the above, found one new, minor (LOW) gap**, not part of the original 4 findings
     and not a new defect in this fix commit's diff (confirmed by `git diff 754c74a 3452c8d --
     index.html`: the code path involved was untouched by this round's fix): `previewImport()`'s
     `errorList` (`index.html` ~4396-4402) builds its user-visible error message text by iterating only
     `parsed.bySheet[sheet].errors` for the 6 entity sheets — it never includes
     `parsed.fieldDefs.errors`. So when a `CustomFieldDefs` sheet row itself is invalid (e.g. the
     "Unknown entity type" case above), the Import Preview's summary **table** does correctly show a
     non-zero error count for that row (`summary.CustomFieldDefs.errors`, via `diffAgainstState`,
     `index.html:1855`), but the actual **message text** explaining what was wrong with it is never
     displayed anywhere in the preview UI — unlike every other sheet's errors, which do get their full
     message text listed below the table. Not destructive, not a crash, the count is still visible, so
     this is **LOW**, not MEDIUM/HIGH: a user importing a foreign/hand-edited file with a bad
     `CustomFieldDefs` row sees "CustomFieldDefs: 1 error" in the table but has to guess what's wrong,
     rather than being told. See `tests/specs/tester-round2-recheck.spec.js`'s "GAP CHECK" test
     (documents the behavior via direct `parsed.fieldDefs.errors` vs. `errorList`-construction code
     inspection rather than asserting a redundant failing expectation).
4. Independent CDN re-check, unchanged from every prior round: `curl -sS -o /dev/null -w
   "HTTP_CODE:%{http_code}" --max-time 8 https://cdn.jsdelivr.net/npm/chart.js` and the SheetJS CDN URL
   both → `CONNECT tunnel failed, response 403` from this shell. Still a known, declared, unchanged
   gap — not a new finding, not something this codebase can fix from inside this sandbox.
5. v1 + rest-of-addendum regression spot check: the full suite (145 total this round: 129 committed +
   my 8 `adversarial-custom-fields-addendum.spec.js` + my 8 new `tester-round2-recheck.spec.js`) covers
   Manage Fields UI CRUD, the Assignment/Skill modals, the v1→v2 migration ladder, and the
   capacity-overage warning via their own dedicated, still-passing specs
   (`custom-fields-addendum.spec.js`, `adversarial-custom-fields-addendum.spec.js`'s migration/capacity
   tests) — none regressed. One flake was observed and chased down: a single full-suite run produced
   `144 passed, 1 failed` on `tester-round3-independent.spec.js`'s `MGR-repro(b)` (an old, pre-existing
   round-3 session-only test, unrelated to this addendum, that uses `waitForTimeout`-based debounce
   windows). Re-ran that spec file alone 3× (`--repeat-each=3`, 18/18 passed) and re-ran the **entire**
   suite fresh a second time (**145 passed, 0 failed**) — confirms this was sandbox-load-sensitive
   timing flake in a test file that predates this round entirely, not a regression from the Coder's
   diff (which never touches `index.html`'s session-only/`hydrated` code at all — confirmed via `git
   diff 754c74a 3452c8d -- index.html`, scoped entirely to `ROE.io`'s `readCustom`/`markImportedCustomKeys`,
   `ROE.store`'s `upsert`, and `ROE.ui`'s Skills Matrix + Demand editor rendering).

**Combined this round: 145/145 passed** (129 pre-existing + 8 `adversarial-custom-fields-addendum.spec.js`
+ 8 new `tester-round2-recheck.spec.js`), across two full clean runs plus an isolated 3× repeat of the
one file that flaked once.

---

## Findings (RE-TEST ROUND 2)

### Confirmed CLOSED this round (the 4 original ADDENDUM 1 findings)

- **1. CRITICAL — re-import silently erasing existing custom values**: **CLOSED.** Confirmed via two
  independent mechanisms this round: my own unmodified original spec (`customAfter` now
  `{"badge_number":555}`, was `undefined`), and a brand-new test with a genuinely self-consistent
  "older-export" file shape covering a value that's present-in-the-file (updates), a value that's
  absent-from-the-file (untouched), and a value that's present-but-blank (explicit clear) — all three
  behave correctly and distinctly. The `__importedCustomKeys` marker + `STORE.upsert()` merge logic is
  real, not test-shaped.
- **2. HIGH — duplicate-label custom fields corrupting each other on re-import**: **CLOSED.** Confirmed
  via my own unmodified original spec and a fresh test that creates the colliding-label defs through
  the **real Manage Fields UI** (not a direct `STORE.addFieldDef()` call) — both values (`North`/
  `South`) round-trip to their own distinct auto-suffixed key.
- **3. HIGH — custom label colliding with a canonical column name misattributes the canonical value**:
  **CLOSED**, for both the primary symptom (canonical "Name" field no longer bleeds into a same-labeled
  custom field) and the secondary symptom I'd only anecdotally noted last round (a Number-typed
  colliding label no longer produces a spurious "'Notes' must be a number" validation error — confirmed
  `errorCount: 0` on a row with a real free-text `Notes` value and a real numeric custom `Notes` value
  side by side).
- **4. MEDIUM — "Unknown skill" claim never actually rendered anywhere**: **CLOSED** in **both** places
  the addendum promised it: the Skills Matrix (an orphan column now appears, confirmed by my original
  spec's panel-text sweep) **and** the Demand editor's required-skills "Resolved:" hint (confirmed fresh
  this round against a `Demand.requiredSkills` reference specifically, which is a separate code path
  `resolvedRequiredSkillsLabel` from the Skills Matrix's orphan-column logic and needed its own,
  independent check).

### New finding this round

### 5. LOW — Import Preview never surfaces the actual error TEXT for an invalid `CustomFieldDefs` sheet row, only a count

**What I did:** Built a hand-crafted workbook whose `CustomFieldDefs` sheet contains one row with an
`EntityType` this app doesn't recognize (`"Vendor"`), parsed it with `IO.parseWorkbook`, and inspected
both `parsed.fieldDefs.errors` (populated correctly, with a real message: `"Unknown entity type
'Vendor'"`) and the code path that builds the Import Preview modal's visible error list
(`previewImport()`, `index.html` ~4396-4409).

**What happened:** `previewImport()`'s `errorList` array is built by iterating
`Object.keys(parsed.bySheet).forEach(...)`, pushing each entity sheet's own row-level errors — but
`parsed.fieldDefs.errors` (the `CustomFieldDefs`-sheet-specific error list, populated separately at
`index.html:1815`) is never included in that loop. The summary **table** row for `CustomFieldDefs` does
correctly show a non-zero error **count** (`diffAgainstState`, `index.html:1855`, reads
`parsed.fieldDefs.errors.length`), so the user isn't told "0 errors" when there's actually a problem —
but the specific message text (which column, which value, why it was rejected) is never displayed
anywhere in the reachable Import Preview UI, unlike every other sheet's errors.

**Why this matters (mildly):** A user importing a hand-edited, foreign, or corrupted file with a bad
`CustomFieldDefs` row sees "CustomFieldDefs: 1 error(s)" in the preview table and has no way to find out
*what* was wrong without opening dev tools — every other sheet in the same preview gives them the exact
message. Not destructive (nothing is silently dropped without the count being visible), not a crash,
and — per the `git diff 754c74a 3452c8d` scoping check above — not introduced or touched by this
round's fix commit at all; it's a pre-existing gap in the original addendum implementation that this
round's adversarial pass happened to surface while specifically probing `CustomFieldDefs`-sheet-level
edge cases (the task's "entity type that isn't represented" angle) rather than entity-sheet-level ones.

**How to reproduce:** `tests/specs/tester-round2-recheck.spec.js`, describe block "NEW ADVERSARIAL
PASS: CustomFieldDefs sheet edge cases beyond the original 4 findings", test "GAP CHECK: does the
Import Preview UI actually surface the CustomFieldDefs-sheet-level error TEXT (not just a count)
anywhere the user can read it?" — documents `fieldDefErrors` (populated) vs. the `errorList`-building
loop at `index.html` ~4402 (which never reads `parsed.fieldDefs.errors`).

**What should happen:** `previewImport()`'s `errorList` construction should also iterate
`parsed.fieldDefs.errors` and push their messages (e.g. `"CustomFieldDefs row " + e.row + " [" +
e.field + "]: " + e.message"`) alongside the per-sheet ones, exactly the way every other sheet's errors
already work.

---

## Overall verdict for this round

**Sign-off ready for the custom-fields addendum's workbook-IO fix specifically.** All 4 defects from the
prior round (1 CRITICAL, 2 HIGH, 1 MEDIUM) are independently confirmed closed under fresh, from-scratch
adversarial re-testing — not just by trusting the Coder's report or re-running existing specs unmodified.
No new CRITICAL or HIGH issue was found despite a genuine, non-trivial additional adversarial pass (real
UI-driven duplicate-label creation, a self-consistent partial-older-export simulation, a
Demand-specific "Unknown skill" check, and two new `CustomFieldDefs`-sheet edge cases neither of us had
tried before). One new LOW-severity UX gap was found and is reported above, pre-existing and unrelated
to this fix's diff — worth a follow-up but not blocking. CDN reachability remains a known, unchanged,
declared environmental gap (still `403`/tunnel-blocked), not a new issue and not this codebase's fault.

**Files this round:** `tests/specs/tester-round2-recheck.spec.js` (new, 8 tests, all passing).
Re-verified unmodified: `tests/specs/adversarial-custom-fields-addendum.spec.js` (8/8, was 4/8).
Full fresh suite: 145/145 across two clean runs (one isolated flake in an unrelated pre-existing
round-3 test, chased down and confirmed to be timing/load-sensitive, not a regression).

---
---

## ADDENDUM 1 pass — custom fields + full manual CRUD (`BUILD_PLAN_ADDENDUM_1.md`) — 2026-08-22

Under test: `index.html` at commit `5ad8974` ("Implement BUILD_PLAN_ADDENDUM_1: custom fields + full
manual CRUD"), against `BUILD_PLAN_ADDENDUM_1.md`'s CF-1..CF-4, NEW-1, NEW-2, IO-1, VERIFY-1, and the
§5 acceptance criteria. This sits on top of the already-GO'd v1 app (`MANAGER_REVIEW.md` final
verdict); v1 regression is spot-checked, not re-verified in full. I did not trust the Coder's
"129/129, VERIFY-1 genuinely blocked" self-report — I ran the full suite fresh myself, then wrote an
independent adversarial spec file targeting exactly the claims the task called out (never-delete-data
on field-def removal, skill-deletion non-cascade, true schema migration, capacity-overage warning,
workbook backward compatibility, CDN reachability) plus several attack angles the Coder's own spec
never touches (duplicate/colliding custom-field labels, re-importing over existing custom data, and
whether "Unknown skill" is actually rendered anywhere or just promised in a confirm dialog).

**Result: I found 4 real, reproducible defects (1 CRITICAL, 2 HIGH, 1 MEDIUM), all in the
workbook-IO/CRUD layer, not in the pure calc/model core.** The custom-field-def CRUD, the "Manage
fields" hide/reveal-without-deleting mechanic, the true IndexedDB schema migration, the deterministic
capacity-overage warning, and the CDN-blocked/VERIFY-1 claim all held up under direct adversarial
attack and are confirmed genuinely correct below. CDN reachability was independently re-confirmed
blocked in this sandbox (not just re-asserted).

**What I ran:**
1. The full committed suite fresh, myself: `npx playwright test --config=pw.local.config.js` (using
   the same uncommitted local Chromium-path override as every prior round — the committed
   `playwright.config.js` still cannot launch a browser in this sandbox, unchanged from every prior
   round's note) → **129 passed, 0 failed** in ~1.9 min. Independently confirms the Coder's reported
   129/129, including all 23 of the Coder's new `tests/specs/custom-fields-addendum.spec.js` tests and
   all 106 pre-existing tests (session-only saga, API connector, presets, auth-mode, horizon
   validation, a11y, perf, calc formulas, mentorship, workbook I/O, boot). This **is** the light v1
   regression spot-check the task asked for — every one of the four prior fix-loop scenarios has its
   own still-passing spec (`adversarial-session-only-round2.spec.js`, `api-connector.spec.js`'s HIGH
   #2 stale-closure test, `optimizer-ui.spec.js`'s preset round-trip test, `adversarial-recheck.spec.js`'s
   auth-mode sequential-edit test) and none regressed.
2. `curl -sS -o /dev/null -w "%{http_code}" --max-time 8 https://cdn.jsdelivr.net/npm/chart.js` from
   this shell, independent of the app/harness: **`CONNECT tunnel failed, response 403`**. The
   suite's own `boot.spec.js`/`workbook-io.spec.js` runs separately reported
   `window.XLSX available in this sandbox: false` and two `ERR_TUNNEL_CONNECTION_FAILED` console
   entries for the two vendor `<script>` tags. Both independently confirm the Coder's VERIFY-1 claim
   is accurate, not just repeated: the CDN is genuinely blocked here too, `exportWorkbookFile`,
   `exportTemplateFile`, `readWorkbookFile`, and both `new Chart(...)` call sites remain **unexecuted
   code** in this environment, same as every prior round. VERIFY-1 stays open pending a
   network-enabled environment; that is not this codebase's fault and is correctly disclosed rather
   than papered over.
3. A new, independent adversarial spec I wrote from scratch (not derived from the Coder's spec),
   `tests/specs/adversarial-custom-fields-addendum.spec.js` (committed test file only, no source
   edits) — 8 tests, **4 failed (documenting real defects below), 4 passed (documenting claims that
   hold up)**:
   - Two "BUG CHECK" tests exploiting `IO.parseSheet`'s `readCustom()`, which matches an imported
     column to a custom-field def **by header text equal to `def.label`**, not by the def's stable
     `key` — see CRITICAL/HIGH #1 and #2 below. **Failed as written (bug confirmed).**
   - A re-import test simulating exactly the scenario `BUILD_PLAN_ADDENDUM_1.md`'s own §5 acceptance
     criteria describe (an older/partial export re-imported over existing local data) but checking
     the thing the Coder's equivalent test never checks: does a **pre-existing** custom value on a
     **matching-ID** record survive a re-import that simply doesn't mention it? **Failed (bug
     confirmed)** — see CRITICAL #1.
   - A DOM-text sweep across every panel after deleting a referenced skill, checking whether the
     literal string "Unknown skill" (promised by NEW-2's confirm dialog and the Coder's own
     self-report) is ever actually rendered anywhere reachable. **Failed** — see MEDIUM #4.
   - A real-UI test: remove a custom field def, re-add one with the identical label (regenerating the
     identical key), reopen the record's edit form — confirms the OLD stored value **auto-repopulates
     the input**, not just "survives in the store but shows blank." **Passed** — this is a genuinely
     stronger, more literal check of the task's "reappears correctly if you re-add a def with the
     same key" instruction than the Coder's own equivalent test, and it holds.
   - A **true** schema-migration test that is strictly stronger than the Coder's own migration spec
     (which only forced `meta.schemaVersion` back to `1` on a database that was, physically, already
     created at `DB_VERSION=2` from first boot — the real `onupgradeneeded(1→2)` generic-store-creation
     branch never actually ran in that version). Mine pre-seeds a **genuinely** version-1 IndexedDB
     (`customFieldDefs` store physically absent, all six other collections + `employeeSkills` +
     `settings` + `meta.schemaVersion:1` populated) **before the app's own boot script ever executes
     once**, via a `page.route()` stub on the first navigation, then lets the real app boot against it
     for the first time. **Passed**: all record counts and a spot-checked field value survive
     byte-for-byte, `customFieldDefs` comes back as `[]` (present, not undefined/missing),
     `meta.schemaVersion` becomes `2`, and a second reload is a stable no-op. This is a real,
     independent confirmation of the migration ladder — not just re-running the Coder's version of it.
   - A deterministic (not probabilistic) capacity-overage test: the Coder's own equivalent test can
     only assert on the warning's wording *if* a toast happens to fire, because the demo-data
     employee/month it picks isn't guaranteed to exceed capacity. Mine forces it (`targetUtil=15`,
     strips the target employee's pre-existing allocations to zero, then allocates 100% for one
     month — guaranteed `100 > 15`). **Passed**: `"Saved, but this exceeds ... effective capacity in:
     2026-01 (100% > 15% capacity)"` fires every time, and the assignment is still saved (never
     blocked). Confirms NEW-1's warn-don't-block requirement is genuinely implemented, not just
     coincidentally green on the Coder's specific demo-data pick.
   - An XSS probe: a custom field label of `<img src=x onerror="window.__xss=true">` added via the
     real "Manage fields" modal. **Passed** — no script execution, no live `<img>` tag, the label
     renders as inert escaped text (`esc()` is applied consistently to labels, matching v1's existing
     discipline elsewhere in the app).

---

## Findings (ADDENDUM 1)

### 1. CRITICAL — Re-importing a workbook silently erases existing custom-field values for any record whose ID is already present, whenever the imported row doesn't carry that record's custom column(s)

**What I did:** Loaded demo data, added an Employee custom Number field ("Badge Number", key
`badge_number`), set `employees[0].custom = { badge_number: 555 }` and persisted it (mirroring the
real "set a value, save" UI flow). Then built a workbook AoA for `Employees` with **the exact same
row** (same ID, same name/email/level/etc., i.e. exactly what an older export, or any export taken
before the field existed, or a hand-edited file with the custom column stripped, would look like —
no `custom` column at all) and ran it through the identical sequence `applyImport()` uses:
`IO.parseWorkbook(...)` → `STORE.restoreFieldDefs(parsed.fieldDefs.toAdd)` → `STORE.upsert("employees",
rec)` for each parsed record.

**What happened:** The employee's `custom` object is now `undefined`. The field **definition** itself
survives (`customFieldDefs.length` unchanged, consistent with CF-2's "defs are never deleted"), but
the **value** that was sitting on that specific record is gone.

**Why:** `parseSheet` builds each imported record entirely from scratch via `M.newEmployee({... custom:
customVals})`, where `customVals` only contains keys for columns actually present in the file's
header row (`readCustom()` at `index.html:1654`). If the file has no matching column for a given
key — which is true by definition for every one of the "backward compatible" scenarios IO-1 explicitly
claims to support — the freshly-built record has **no** `custom` object at all (`withCustom` omits it
when empty, `index.html:435`). `applyImport()` (`index.html:4319-4340`) then does
`STORE.upsert(map[sheet], rec)` for every parsed row, and `STORE.upsert` (`index.html:2651-2658`) is a
**full-record replace by ID** (`arr[idx] = record`), not a merge. The freshly-built (custom-less)
record completely replaces the existing on-disk record, taking its custom values down with it.

**Why this matters:** This directly contradicts the addendum's own explicit design principle, stated
no fewer than three times in `BUILD_PLAN_ADDENDUM_1.md` (CF-2, IO-1, §5) — "never silently delete
data" — and contradicts the Coder's own self-report ("claims backward compatible with older files
lacking the sheet entirely (absence = no custom values, not an error)"). That claim is only true for
the **freshly parsed record in isolation**; it becomes false the moment that record is applied over
an existing one with the same ID. This is not a contrived edge case: it is the literal, headline
scenario IO-1 §5's acceptance bullet #3 describes ("does not break existing (pre-addendum) exported
files") and the everyday case of re-importing any file — including the app's own "downloadable
template" or a hand-edited partial re-export — that is missing even one custom column the local
record already has a value for. Every custom value entered since a given export was taken is at risk
of being wiped the next time that same file (or any older/partial file sharing those IDs) is
re-imported.

**How to reproduce:** `tests/specs/adversarial-custom-fields-addendum.spec.js`, describe block
`"ADVERSARIAL: re-importing a workbook must never silently erase existing custom values not present
in the file"` (currently failing — `expect(result.customAfter).toEqual({ badge_number: 555 })`,
receives `undefined`).

**What should happen:** Import should merge `custom` (and arguably other optional/append-only data)
rather than fully replacing the record, or at minimum preserve `record.custom` keys that have no
corresponding column in the imported sheet — symmetric with how CF-2 already protects values when a
**field def** is removed. Right now that protection only covers the "def removed" path, not the
"record re-imported" path, and the latter is the one users will hit constantly.

---

### 2. HIGH — Two custom-field defs on the same entity type sharing an identical label corrupt each other's data on every workbook export → re-import cycle

**What I did:** Added two Employee custom-field defs both labeled "Region" (nothing in the "Manage
fields" UI — `openManageFieldsModal`, `index.html:3237-3275` — or `STORE.addFieldDef` prevents
duplicate labels; only the auto-generated **key** is de-duplicated, via suffixing, at
`index.html:482-491`, so this produces two real defs: `key="region"` and `key="region_2"`, both
labeled "Region"). Set an employee's `custom = { region: "East", region_2: "West" }`, built the
workbook, and re-parsed it.

**What happened:** The built sheet correctly contains **both** values in two separate "Region"-headed
columns (`["East","West"]` — the export side is fine). But on re-import, both `region` and `region_2`
come back as `"East"` — the second def's data is silently overwritten by the first's.

**Why:** `readCustom()` (`index.html:1654-1673`) locates a def's column via
`headers.indexOf(def.label)` — a plain-array `indexOf`, which always returns the **first** matching
header index. Both defs share the label "Region", so both look up the same (first) column.

**How to reproduce:** `adversarial-custom-fields-addendum.spec.js`, `"BUG CHECK: two custom fields on
the same entity sharing an identical LABEL..."` (currently failing —
`expect(result.reparsedCustom[result.keyB]).toBe("West")`, receives `"East"`).

**What should happen:** Column matching on import must key off something unique per def — either
persist the def's `key` in the header (or an adjacent hidden column/marker) rather than its
user-editable `label`, or reject/auto-disambiguate duplicate labels for the same entity type at
creation time in `openManageFieldsModal`.

---

### 3. HIGH — A custom-field label identical to a canonical column name for that entity (e.g. "Name") causes the wrong column to be read back on import, misattributing the record's own canonical field value as the custom value

**What I did:** Added an Employee custom-field def literally labeled "Name" (again, nothing blocks
this). Set `employee.name = "Real Employee Name"` and `employee.custom.name = "CUSTOM_FIELD_VALUE"`
(distinct values, deliberately). Exported and re-parsed.

**What happened:** The canonical `Name` field survives correctly ("Real Employee Name"). The custom
field, however, comes back as `"Real Employee Name"` too — it silently picked up the **canonical**
column's value instead of its own, distinct trailing column.

**Why:** Same root cause as #2 — `headers.indexOf(def.label)` in `readCustom()` returns the first
column named "Name", which is the canonical Employee-name column (index 1), not the custom column the
addendum appended at the end of the row (`buildWorkbookSheets`, `index.html:1528`, appends custom
columns strictly after the canonical ones — but `indexOf` doesn't know that).

**Secondary, less severe symptom noted while probing this:** if the colliding custom field is typed
**Number** instead of Text (e.g. label "Notes", type Number, colliding with the canonical free-text
`Notes` column), the misread canonical text value fails `parseFloat`, and the import surfaces a
spurious, confusing row-level error ("'Notes' must be a number") on an otherwise perfectly valid row —
the row still imports (because the resulting `custom` object ends up empty and CF-4 treats absent
custom as valid), but the user sees an error message that has nothing to do with anything they
actually entered.

**How to reproduce:** `adversarial-custom-fields-addendum.spec.js`, `"BUG CHECK: a custom field label
identical to a canonical column name ('Name')..."` (currently failing —
`expect(result.customValueAfterReparse).toBe("CUSTOM_FIELD_VALUE")`, receives `"Real Employee Name"`).

**What should happen:** Same fix direction as #2 — column identity for custom fields must not be
determined by a plain string match against the same label-space as the canonical, hard-coded
`COLUMNS` headers. At minimum, `openManageFieldsModal`/`addFieldDef` should refuse a label that
collides (case-insensitively) with that entity's own canonical column set.

---

### 4. MEDIUM — NEW-2's "orphaned skill references render as 'Unknown skill' rather than crashing" is only ever true as a promise in a `confirm()` dialog string; the text is never actually rendered anywhere in the reachable UI

**What I did:** Deleted a skill referenced by existing `EmployeeSkill` rows (confirming the dialog),
then swept every panel's `document.body.innerText` for the literal string "Unknown skill".

**What happened:** The app does **not** crash (confirmed — matches the claim on that half), and the
orphaned `EmployeeSkill` rows are correctly left in place, never cascade-deleted (also confirmed, and
already covered by the Coder's own test). But the string "Unknown skill" never appears anywhere. The
Skills Matrix (`renderSkills`, `index.html:2916-2964`) builds its skill columns by iterating
`state.skills` (the live catalog), so a deleted skill's column simply **disappears** from the grid —
any orphaned `EmployeeSkill` row referencing it becomes invisible, not labeled "Unknown skill." The
Demand editor's required-skills field (`index.html:3324-3325`) only ever displays the raw
`skillId:minLevel:weight` encoding, never a resolved skill name either way, so an orphaned
`requiredSkills.skillId` there is likewise never rendered as "Unknown skill" — it just shows the raw
(now-dangling) ID string, same as it would for a *valid* skill.

**Why this matters:** It's not destructive and it's not a crash — the two things the acceptance
criterion cares about most are genuinely satisfied. But the specific, quotable UI behavior promised
twice (once in the confirm-dialog copy the user actually sees before deleting, and once in the
Coder's self-report: `orphaned references should render as "Unknown skill" rather than crash`) does
not exist anywhere a user can reach it. A user who deletes a referenced skill sees a warning that
implies stale references will be visibly marked, and instead they just quietly vanish from view with
no marker at all — which is arguably a worse outcome for discoverability than an explicit "Unknown
skill" label would have been (the data survives, per CF-2/NEW-2's letter, but its absence is now
silent rather than visible).

**How to reproduce:** `adversarial-custom-fields-addendum.spec.js`, `"ADVERSARIAL: 'Unknown skill'
claim for orphaned skill references"` (currently failing by construction —
`expect(found).toBe(true)`, receives `false`, documenting the gap rather than asserting a bug that
crashes anything).

**What should happen:** Either implement an actual "Unknown skill" fallback label somewhere a user can
see it (e.g. the Skills Matrix could still render a column, or an indicator, for a skill ID that has
`EmployeeSkill` rows but no matching catalog entry), or soften the confirm-dialog copy and self-report
to match what's actually implemented (silent-but-non-destructive, not "rendered as Unknown skill").

---

## Confirmed correct under adversarial attack (ADDENDUM 1)

- **CF-2 "never delete stored values when a field def is removed"**: holds, both at the pure-function
  level (Coder's own tests) and at the real-UI level *with the added twist of re-adding a def with
  the identical label/key afterward* — the old value doesn't just survive in the store, it correctly
  **repopulates the form input** the moment the same key exists again. This is a stronger bar than the
  Coder's own test cleared, and it passed.
- **The v1 → v2 schema migration** (`customFieldDefs` store, `meta.schemaVersion` 1→2) is genuinely
  sound: verified against a **physically** version-1 IndexedDB (not a database that was already v2
  the whole time with only the meta flag faked), created before the app's boot script ever ran once.
  Zero data loss across all 6 collections + `employeeSkills`, the store comes back present-but-empty
  (not missing/undefined), and a second reload is a stable no-op.
- **NEW-1's capacity-overage warning** fires deterministically (not just "sometimes, depending on demo
  data") and never blocks the save — confirmed by forcibly engineering a guaranteed-over-capacity
  scenario rather than relying on the Coder's probabilistic demo-data pick.
- **VERIFY-1 / CDN-blocked claim**: independently re-confirmed via a direct `curl` from this shell
  (403/tunnel failure against `cdn.jsdelivr.net`) plus the suite's own boot console output — this
  sandbox genuinely cannot reach the CDN, matching the Coder's disclosure. SheetJS/Chart.js real-file
  and real-render verification remains genuinely open, not silently dropped.
- **Custom-field label injection (XSS)**: a label containing a live `<img onerror>` payload renders as
  inert escaped text in both the "Manage fields" table and the form input; no script execution.
- **v1 regression** (session-only mode, API connector UI + field mapping, optimizer preset
  fidelity, auth-mode sequential-field-edit stale-closure fix): all still green, all still covered by
  their own dedicated specs, none touched or broken by this addendum's diff.

---

## Files (ADDENDUM 1)

- New independent adversarial spec: `tests/specs/adversarial-custom-fields-addendum.spec.js` (8 tests,
  4 failing/documenting-defects, 4 passing/confirming-correctness).
- Re-run, unmodified, and passing: the entire committed suite including the Coder's new
  `tests/specs/custom-fields-addendum.spec.js` (23 tests) and all 106 pre-addendum tests.
- Full fresh run: `npx playwright test --config=pw.local.config.js` → 129/129 passed (committed
  suite, ~1.9 min); 133/137 including my own new file (4 failures are the documented findings above,
  not flakes — each reproduced deterministically on every run).
- Independent CDN check: `curl -sS -o /dev/null -w "%{http_code}" --max-time 8
  https://cdn.jsdelivr.net/npm/chart.js` → `CONNECT tunnel failed, response 403` from this shell,
  outside the Playwright/browser harness entirely.
- Source under test: `index.html` at commit `5ad8974`.
- Plan: `BUILD_PLAN_ADDENDUM_1.md`. Prior verdict basis: `MANAGER_REVIEW.md` (v1 final, GO), round-3
  and earlier sections below, preserved unchanged.

---
---

## Re-test pass ROUND 3 (Fix loop 3 verification — FINAL LOOP) — 2026-08-21

This is the **final adversarial pass** of this pipeline (fix loop 3 of a maximum of 3; no further
loop is available regardless of outcome). Under test: `index.html` at commit `3d4aa9b` ("Fix loop 3
(final): reload-gate the session-only toggle"), against `MANAGER_REVIEW.md` round-2's one mandatory
blocking finding (three failure modes, labeled (a)/(b)/(c) there) and my own round-2 HIGH finding
(preserved below). I did not take the Coder's "95/95, structurally closes all three at once" summary
on report: I re-ran the full suite fresh myself, then re-implemented the Manager's exact three repro
scenarios independently (own spec file, not the Coder's rewritten one), then went looking for new
failure modes in the same region a third time (toggle races, rapid flip-flops, the plain/default
non-session-only path, and a genuinely first-ever boot).

**Result: I could not break it. All three of the Manager's round-2 failure modes are now closed, the
plain/default persistence path is unaffected, and I found no new CRITICAL/HIGH/MEDIUM issues in this
region on this pass.** The session-only saga is closed as of this loop, with one caveat below.

**Environment note (unchanged across all three rounds):** same sandboxed-proxy constraint, same
local, uncommitted `tests/pw.local.config.js` override pointing at
`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`. The committed `tests/playwright.config.js`
still cannot launch a browser here; out of scope, already logged three times now.

**What I ran:**
1. The full committed suite fresh, myself: `npx playwright test --config=pw.local.config.js` →
   **95 passed, 0 failed** (~75s). Independently confirms the Coder's reported 95/95, including the
   Coder's rewritten `adversarial-session-only-round2.spec.js` (corrected assertions "(a)"/"(b)" plus
   three new tests "(d)"/"(e)"/"(g)") and the corrected `persistence.spec.js` assertion, all passing.
2. A brand-new, independent spec file I wrote from scratch, not derived from or reusing the Coder's
   test code: `tests/specs/tester-round3-independent.spec.js`. Reads IndexedDB **directly** via raw
   `indexedDB.open()`/object-store `count()`/`get()` calls rather than trusting `ROE.db`'s own
   reporting, so a bug in the app's own instrumentation can't hide a real on-disk discrepancy. Six
   tests, covering the Manager's exact three repro scenarios plus two regression checks:
   - `MGR-repro(a)`: boot normal (hydrated) → check ON → add data → uncheck OFF, no reload → disk.
   - `MGR-repro(a2)`: **true** session-only window (after an actual session-only reload) → add data →
     uncheck OFF, no reload → disk.
   - `MGR-repro(b)`: true session-only window → delete/churn records → uncheck OFF, no reload → disk,
     then a real reload to confirm the pre-existing baseline (not the session churn) survives.
   - `MGR-repro(c)`: session-only reload → uncheck OFF, no reload → badge vs. `isPersistenceActive()`
     vs. actual disk state, checked immediately.
   - Regression check: plain/default (never-touches-the-checkbox) add→delete→reload cycle.
   - Regression check: a genuinely first-ever boot (fresh isolated Playwright context, no prior `roe`
     database at all) is `hydrated = true` and persists demo data normally.
   All 6 passed.
3. A second independent spec, `tests/specs/tester-mgr5-transparency-check.spec.js`, specifically
   re-testing the Manager's MGR-5 scenario (deletion committed on toggle-off without reload) under
   the **still-hydrated** condition (never went through a session-only reload) to confirm the new
   design's documented trade-off — see "Confirmed closed" #2 below. Passed.
4. Two throwaway race/ordering probes (`tester-race-check.spec.js`, `tester-fliptoggle-check.spec.js`,
   10 executions total across `--repeat-each` and manual sequencing) targeting scenarios the Coder's
   own tests don't touch: reloading with zero delay after toggling (checking for a lost async
   `savePreference` write racing an unload), and rapid flip-flop toggling (ON→OFF→ON, and ON→OFF)
   before ever reloading, to confirm the *last* toggle before reload is the one that's honored. Both
   held up in every trial (10/10 and 2/2 respectively) — no lost writes, no stale state.
5. `git diff 47cad26 3d4aa9b -- index.html` reviewed by hand, in full: confirms the entire round-3 diff
   is confined to the exact region the Manager scoped (`hydrated`'s declaration comment,
   `scheduleSave`/`persist`'s guard, `setSessionOnly`'s no-longer-conditional-`scheduleSave` removal,
   the new `isPersistenceActive()`, `updateSessionBadge()`'s binding, and two blocks of user-facing
   copy: the settings-panel hint and the toast text). Nothing in the calc engine, optimizer, alerts,
   mentorship, API connector, a11y, perf, or CSV-export code paths was touched — no scope creep.

**Total combined this session: 105 passed, 0 failed** (95 committed + 10 of my own new/independent).

---

## Confirmed closed this round (the Manager's three round-2 failure modes)

### 1. (a)/(d) — New data added while session-only is genuinely active (post-session-only-reload) is no longer written to disk on toggle-off without a reload

Verified directly against raw IndexedDB (not `ROE.db`'s own reporting): boot normally → load demo
(40 records on disk) → check session-only → **reload** (now genuinely `hydrated = false`) → add one
record in memory → uncheck the box **without reloading** → wait past the debounce → raw
`indexedDB.open("roe")` → `employees` store `count()` still **40**, the new record never lands on
disk (`MGR-A2-repro: {"baseline":40,"diskCountNoReload":40}`). This is the scenario that actually
matches "session-only mode was truly active" — `hydrated` never flips back to `true` without an
actual reload, so `scheduleSave`/`persist`'s sole gate holds for the entire un-hydrated window
regardless of how many times the checkbox is flipped in between. Root cause fix (`hydrated`
completely decoupled from `state.settings.sessionOnly`, per the code comments at
`index.html:2204-2215` and `index.html:2353-2361`) is real, not test-shaped.

### 2. (b)/(e) — Deletions made during a genuine session-only window are not committed on toggle-off without reload

Same mechanism as above, tested with destructive edits instead of additions: true session-only
window → seed 10 records in memory → delete 5 of them → uncheck without reloading → raw disk count
is still the **pre-session-only baseline** (`MGR-B-repro: {"baseline":40,"diskCountNoReload":40}`),
and a subsequent real reload restores exactly the baseline, not the session's churn
(`finalCount === baseline`). The round-2 CRITICAL-class defect (data destroyed via a doorway nobody
had tested) is closed.

**Important nuance, not a new bug:** if the session was **already hydrated** when the checkbox is
checked (i.e., the user never actually went through a session-only reload — they just ticked the box
mid-session), deletions made in that window **are** genuinely committed to disk immediately,
regardless of the checkbox state (`MGR-5-equivalent: {"before":40,"afterDeleteAndUncheckNoReload":35,
"afterReload":35}`). This is now **by design, and transparently so**: `hydrated` only reflects actual
reload state, never the pending checkbox, so until a reload happens the app keeps behaving exactly as
it already was — and, critically, the session badge stayed accurately hidden (`writing = true`)
through the entire sequence, so the user was never told otherwise. This is the key difference from
round 2: the same underlying data movement is no longer a **lie** — the toast, the settings-panel
hint, and the badge all agree with what's actually happening at every step. I verified this
transparency claim directly rather than taking the code comments' word for it.

### 3. (c)/(g) — The session badge no longer claims a write-state that isn't real

Checked the exact adversarial sequence: session-only reload (genuinely `hydrated = false`) → uncheck
the box **without reloading** → immediately read `#session-badge`'s visibility, `isPersistenceActive()`,
and raw disk state, all in the same tick-adjacent window (no reload in between). Result:
`{"badgeVisible":true,"actuallyWriting":false,"diskCount":40,"baseline":40}` — the badge stayed
visible (truthfully claiming "not saving") even though the checkbox now reads unchecked, because it's
bound to `isPersistenceActive()` (i.e. `hydrated`), not the raw settings value. This is the exact
inversion of round 2's MGR-7 finding (badge disappearing while writes were actually still off) and it
no longer reproduces. Also re-verified via the flip-flop probe that badge state and disk state track
`hydrated` consistently across a full boot→toggle→reload→toggle→reload cycle, not just a single
transition.

---

## Regression check: the plain/default persistence path (the one every ordinary user hits)

This was the task's explicit concern: gating everything on `hydrated` instead of the raw setting
could have broken persistence for the overwhelming majority of users who never touch the session-only
checkbox at all. Verified this is **not** the case:
- A genuinely first-ever boot (fresh isolated browser context, no prior `roe` IndexedDB database at
  all — Playwright gives each test its own storage by default, so no explicit teardown was even
  needed) comes up with `isPersistenceActive() === true` immediately, before any user interaction.
  Loading demo data persists to disk normally.
- In an ordinary (non-session-only) session: add → disk count increments; delete → disk count
  decrements; reload → `hydrated` is `true` again, badge is hidden, record count matches. All four
  assertions passed against raw IndexedDB reads.
- The full 95-test committed suite, which is overwhelmingly non-session-only-focused (formulas,
  optimizer, alerts, mentorship, API connector, workbook I/O, a11y, perf, the base `persistence.spec.js`
  reload test), passed without modification.

No regression in the default path.

---

## Spot-check: everything outside the persistence region

Per the task's own scoping instruction, this was a fresh full-suite run rather than manual
re-verification of already-settled areas, since the round-3 diff (verified by hand via
`git diff 47cad26 3d4aa9b -- index.html`) touches only `ROE.store`'s `hydrated`/`scheduleSave`/
`persist`/`setSessionOnly`/`isPersistenceActive`, `ROE.ui.updateSessionBadge`, and two blocks of
settings-panel/toast copy — nothing in `calc-formulas.spec.js`, `autostaff-demo.spec.js`,
`optimizer-ui.spec.js`, `api-connector.spec.js`, `a11y.spec.js`, `perf.spec.js`, or
`workbook-io.spec.js`'s target code. All of these pass unmodified in the same fresh 95/95 run. No new
information suggesting any regression here.

---

## What I tried and could not break (round 3)

- Re-implemented all three Manager repro scenarios independently, reading raw IndexedDB rather than
  trusting the app's or the Coder's own instrumentation — all three now behave correctly.
- Reloaded with **zero** added delay immediately after toggling the checkbox, 5x repeated, to look
  for a lost/raced async `savePreference` write against an immediate reload — held up 5/5 (10/10
  across both a 0ms and 10ms variant).
- Rapid flip-flop toggling (ON→OFF→ON and ON→OFF, both within ~50ms, before ever reloading) to check
  that the *last* write wins and no stale preference sticks — held up in both directions.
- Deliberately distinguished the "session actually booted un-hydrated" case from the "checkbox is
  pending but session is still hydrated" case, since conflating these was exactly what let round 2's
  three bugs hide — confirmed the code (and my tests) correctly distinguish them, and confirmed the
  latter case's continued-writing behavior is honestly reflected everywhere (toast, hint text, badge),
  not silently divergent from it.
- Tried to find a scenario where the badge and `isPersistenceActive()`/actual disk-write behavior
  disagree, across every toggle/reload permutation I could construct — could not produce one.

---

## Caveat (not a defect, a documentation/UX observation — LOW, non-blocking)

The checkbox's own inline label still reads *"Session only - do not persist to IndexedDB"*, which,
read in isolation and without the paragraph immediately below it, could be misread as taking effect
the instant it's checked. The hint paragraph directly underneath it does fully and correctly explain
the reload-gating and even states the badge is the source of truth — so this is not a functional gap,
just a minor first-impression risk for a user who reads the checkbox label but skips the hint. Since
the actual behavior, the toast, the hint text, and the badge are now all mutually consistent (the
substantive requirement), I am not rating this above LOW, and given this is the final loop with no
further fix cycle available, I'm documenting it rather than blocking on it. Recommend, if this project
ever gets a loop 4 for unrelated reasons, tightening the checkbox label itself (e.g. appending
"(takes effect after reload)").

---

## Verdict recommendation (round 3, final)

**GO.** All three of Manager round-2's failure modes ((a) over-persistence, (b) destructive
under-toggle-off, (c) badge dishonesty) are independently confirmed closed under my own from-scratch
adversarial re-implementation, reading raw IndexedDB rather than trusting either the app's or the
Coder's own reporting. The plain/default persistence path (the one every ordinary user hits, having
never touched this checkbox) is unaffected — verified via a genuinely first-ever boot and an ordinary
add/delete/reload cycle. Nothing outside the persistence region regressed (95/95 committed, unmodified
elsewhere). I could not break this in five separate additional adversarial angles (raw-disk
verification, zero-delay reload race, rapid flip-flop toggling, still-hydrated-mid-session
transparency check, first-ever-boot check). The session-only saga, open across three consecutive fix
loops, is closed as of this commit. The one open item (checkbox label wording, LOW) is a
documentable, non-blocking cosmetic note, not a functional defect, and does not change the GO
recommendation — especially given this is the final loop and the pipeline must conclude regardless.

---

## Files (round 3)

- New independent specs (raw-IndexedDB-reading, not derived from the Coder's rewritten specs):
  `tests/specs/tester-round3-independent.spec.js` (6 tests), `tests/specs/tester-mgr5-transparency-check.spec.js`
  (1 test).
- Exploratory probes (race/ordering, not core regression coverage but zero failures across all runs):
  `tests/specs/tester-race-check.spec.js`, `tests/specs/tester-fliptoggle-check.spec.js`.
- Re-run, unmodified, and passing: the entire committed suite including the Coder's rewritten
  `tests/specs/adversarial-session-only-round2.spec.js` and corrected `tests/specs/persistence.spec.js`.
- Full fresh run: `npx playwright test --config=pw.local.config.js` → 95/95 passed (committed suite);
  105/105 including my own new files.
- Source under test: `index.html` at commit `3d4aa9b`. Diff reviewed by hand:
  `git diff 47cad26 3d4aa9b -- index.html`.
- Plan: `BUILD_PLAN.md` §2.6 (still not amended by the Architect per Manager round-2's request — out
  of scope for the Coder/Tester, noting for the record only).
- Prior verdict basis: `MANAGER_REVIEW.md` (round 2, GO WITH FIXES), round-2 and round-1 sections
  below, preserved unchanged.

---
---

## Re-test pass ROUND 2 (Fix loop 2 verification) — 2026-08-21

This is an **independent re-verification** of the Coder's fix-loop-2 commit (`95e9df5`), following
up on my own round-1 `TEST_REPORT.md` findings (below, preserved unchanged). I did not trust the
Coder's "83/83, all my adversarial specs pass unmodified" summary at face value: I re-ran the exact
committed spec files myself, then re-ran my own three round-1 adversarial specs unmodified, then wrote
new adversarial variants targeting scenarios the Coder's own new code/tests do not appear to exercise
(same-session toggle-without-reload, empty-app-start, and a wider set of horizon inputs).

**Result: three of three round-1 blocking items hold up. I found one new HIGH-severity issue that the
Coder did not test for and that directly contradicts new UI copy added in this exact patch.** It is
not a data-destroying regression like last round's CRITICAL — it's the opposite failure mode: data the
user believes is "session only / not being saved" gets silently written to IndexedDB the moment
session-only is turned back off, if that happens in the same session without an intervening reload.

**Environment note (unchanged from both prior rounds):** same sandboxed-proxy constraint, same local,
uncommitted `tests/pw.local.config.js` override pointing at
`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`. The committed `tests/playwright.config.js` still
cannot launch a browser here; out of scope, already logged twice.

**What I ran:**
1. The full committed suite fresh, myself, not trusting the Coder's reported count:
   `npx playwright test --config=pw.local.config.js` → **83 passed, 0 failed** (56.0s). This
   independently confirms the Coder's reported 83/83 is real, including all four of my own round-1
   adversarial spec files (`adversarial-session-only.spec.js`, `adversarial-recheck.spec.js`,
   `adversarial-clearall.spec.js`, `adversarial-horizon-edge.spec.js`) running **unmodified** and
   passing for the first time.
2. `adversarial-session-only.spec.js` alone under `--repeat-each=3` → 3/3 passed, confirming the
   fix for last round's CRITICAL is 100% reproducible, not a lucky single run.
3. Two new spec files of my own:
   - `tests/specs/adversarial-session-only-round2.spec.js` — same-session toggle-without-reload
     scenario, empty-app-start scenario, and a 3x-repeated full-cycle stability check.
   - `tests/specs/adversarial-horizon-edge2.spec.js` — six more horizonStart inputs beyond last
     round's `"2026-13"` (`"2026-00"`, `"0000-01"`, `"2026-1"`, `"2026-AA"`, `"9999-12"`, `"2026-99"`).

---

## CRITICAL

**None open.** Last round's CRITICAL (turning session-only OFF after a reload silently destroyed
previously-persisted IndexedDB data) is **confirmed fixed**, independently, including under repeat
testing. See "Confirmed fixed" section below for detail.

---

## HIGH

### NEW — Data added while session-only is ON gets silently written to IndexedDB the instant the box is unchecked, if this happens within the same session without a reload in between

**§9 / UI-copy criterion this breaks:** the settings panel's own hint text, rewritten in this exact
patch (`index.html:3316`), states: *"Turning it OFF does NOT immediately resume saving or load your
existing data back in - nothing is written to IndexedDB until you reload the page."* This claim is
demonstrably false for the most ordinary version of this flow: toggle on, do something, toggle off,
all without ever reloading.

**Root cause:** the new `hydrated` guard (the actual fix for last round's CRITICAL) is only ever set
to `false` inside `load()` — i.e., only a real page load/reload can make it `false`. Checking the
session-only checkbox (`setSessionOnly(true)`) does **not** touch `hydrated` at all; it stays `true`
if the app booted normally. So the moment the user unchecks it again (`setSessionOnly(false)` →
`scheduleSave()`), the `if (!hydrated) return;` guard added this loop does **nothing** to stop it,
because `hydrated` was never flipped false in the first place — there was no intervening reload. The
guard only protects the specific "empty in-memory state right after a session-only reload" case it was
built for; it does not protect the "same-session round-trip" case, because in that case nothing about
the in-memory state ever looked suspicious to the code (no emptiness, no reload) even though the data
in it was added under an explicit privacy promise.

**What I did (own adversarial test, `adversarial-session-only-round2.spec.js`, test "(a)"):**
1. Loaded the app, loaded demo data (~40 employees), waited for persist (real IndexedDB now holds 40).
2. Checked `#set-sessionOnly` via the real checkbox.
3. **Without reloading**, added one new employee record via `ROE.store.upsert("employees", ...)`
   (equivalent to using any real "add employee" UI action while the privacy toggle is on) — the
   in-memory array now holds 41.
4. **Without reloading**, unchecked `#set-sessionOnly` again.
5. Waited 700ms (well past the 400ms debounce).

**What happened:** `ROE.db.readAll("employees")` now returns **41** records, including the one added
in step 3 under the "session only, not saved" premise. It was written to disk with zero reload, zero
warning, zero further user action beyond unchecking one box.

**What should have happened:** either (a) the record added while session-only was on should never
reach IndexedDB unless/until the user takes an action the app clearly frames as "start persisting
again" (e.g., an explicit reload, exactly as the UI hint text already claims happens), or (b) if
same-session flush-on-toggle-off is the intended design, the UI hint must not claim otherwise. Right
now the code and its own freshly-written user-facing copy disagree with each other.

**Confirmed with a second, independent scenario** (test "(b)"): starting from a **completely empty**
app/IndexedDB (no demo data loaded at all), toggling session-only ON, adding one record, toggling OFF
(no reload), then reloading: the "ephemeral" record survives the reload and IndexedDB shows 1 record
— not 0. So this isn't specific to "there was already data sitting around"; it reproduces from a blank
slate too.

**Severity reasoning (HIGH, not CRITICAL):** this is the inverse failure mode of last round's
CRITICAL — over-persistence of data the user believed was private, not destruction of existing data.
No data is lost; nothing crashes. But it is a real privacy-contract violation of the feature's entire
stated purpose ("session only — do not persist to IndexedDB") in an entirely ordinary flow (nobody is
required to reload between checking and unchecking a settings checkbox), and it falsifies UI copy the
Coder wrote in this very commit to describe this exact fix. Not rated CRITICAL because: (1) it doesn't
destroy pre-existing data, (2) the literal §9 bullet ("when on, all writes are skipped") is honored
while the box is actually checked — the violation is specifically about what happens after it's
unchecked again, a case §9 does not explicitly speak to. This is a genuine, real gap, not scope creep:
it was directly in-scope of what this loop's own fix and its own new UI text claim to guarantee.

**Note on novelty:** the underlying mechanism (`setSessionOnly(false)` unconditionally calling
`scheduleSave()` against whatever is currently in memory) is *not new to this loop* — it existed in
loop 1 too, and my own round-1 report noted toggling on/off without reloading "correctly safe, no data
loss" because I hadn't yet tried adding new data during the ON window. What **is** new to this loop is
the UI hint text that now makes an affirmatively false claim about this exact scenario ("nothing is
written to IndexedDB until you reload the page"), which is why I'm flagging it now rather than treating
it as previously-accepted behavior.

**Reproduce:** `tests/specs/adversarial-session-only-round2.spec.js`, tests "(a)" and "(b)".

---

## Confirmed fixed (round 1 blockers, independently re-verified this round)

### 1. CRITICAL — session-only OFF after a reload no longer destroys previously-persisted data

Re-ran my own unmodified `adversarial-session-only.spec.js` (the exact repro from last round) plus
`--repeat-each=3` for reproducibility. **3/3 passed.** Read the actual fix in `index.html`:
- A new `hydrated` flag (`index.html:2210-2219`) starts `false`, is set `true` only on the real
  disk-read branch of `load()` (`index.html:2302`), and `false` on every non-hydrating branch
  (DB-unavailable, session-only-skip, error-fallback).
- `scheduleSave()` (`index.html:2237-2241`) and `persist()` (`index.html:2244-2247`) both now bail
  immediately if `!hydrated`, in addition to the pre-existing `sessionOnly` bail.
- `setSessionOnly(false)` still calls `scheduleSave()`, but since `hydrated` is still `false` at that
  point (it was never flipped true after the session-only-skip boot), the call is now a no-op. Only a
  subsequent real reload (which re-runs `load()`, sees `sessionOnly` now `false`, takes the disk-read
  branch, and sets `hydrated = true`) makes writes possible again.
- Confirmed via direct IndexedDB inspection at every step: toggle ON → reload → in-memory 0, IDB still
  40 → toggle OFF (no reload) → wait 700ms → IDB **still 40** (was: 0, last round) → reload → in-memory
  and IDB both 40. This is a correct, real fix of the exact reported defect.

### 2. MEDIUM — "Clear all data" leftover `settings` preference record

Re-ran my own unmodified `adversarial-clearall.spec.js`. **Passed.** `ROE.db.readAll("settings")`
returns `[]` (empty array) after typing `CLEAR`, not the `[{"sessionOnly":false,"theme":"dark"}]` from
last round. Read the fix: `clearAll()` (`index.html:2333-2346`) no longer calls `DB.savePreference(...)`
after `DB.clearAll()` — it resets `state.settings` fully to `C.DEFAULT_SETTINGS` in memory and leaves
every store, including `settings`, genuinely empty on disk. Matches the literal §9 wording ("leaves
every object store empty") exactly now.

### 3. LOW — horizonStart month-range validation

Re-ran my own unmodified `adversarial-horizon-edge.spec.js`. **Passed** — `"2026-13"` is now rejected
and reverted with the inline error shown (updated error text: "...with a month between 01 and 12...").
I went further this round with `adversarial-horizon-edge2.spec.js`, six more inputs:

| Input | Result |
|---|---|
| `"2026-00"` | rejected, reverted to prior valid value |
| `"2026-1"` (wrong shape) | rejected, reverted |
| `"2026-AA"` (non-numeric month) | rejected, reverted |
| `"2026-99"` | rejected, reverted |
| `"9999-12"` (valid shape+range, unusual year) | **accepted** (correct — nothing in scope says to bound the year) |
| `"0000-01"` (valid shape+range, year zero) | accepted, stored as `"0000-01"` |

All the actually-in-scope cases (bad shape, non-numeric month, out-of-range month including both `00`
and `99`) are now correctly caught. `"0000-01"` sailing through is a trivial residual (a literal year
zero is nonsensical but shape-and-range valid, and month-range was the only thing this loop was asked
to fix) — noting it for completeness, **not** escalating it as a new finding; it's out of proportion
with what §9/this loop's scope actually required, and no downstream crash or corruption was found from
it.

### 4-6. API connector UI, auth-mode stale closure, preset round-trip

Not re-tested from scratch this round per the task's own scoping instruction (these were independently
confirmed in round 1 and this loop did not touch that code). Spot-checked only via the full suite
(`api-connector.spec.js`, `optimizer-ui.spec.js`, and my own `adversarial-recheck.spec.js` all still
pass unmodified, 0 changes needed). No regressions detected.

---

## Regression spot-check (formulas, determinism, auto-staff, alerts, mentorship, a11y, perf, CSV gating)

Per the task's scoping instruction, this was a spot-check via the full fresh suite run rather than
manual re-verification, since this loop's diff (`git diff HEAD~1 HEAD -- index.html`) touches only
`ROE.store.load/scheduleSave/persist/clearAll/setSessionOnly` and the horizon-input validation handler
— nothing in the calc engine, optimizer, alerts, mentorship, a11y, perf, or CSV-export code paths.
`calc-formulas.spec.js`, `autostaff-demo.spec.js`, `a11y.spec.js`, `perf.spec.js`, `workbook-io.spec.js`,
`api-connector.spec.js`, `optimizer-ui.spec.js`, and `persistence.spec.js` all pass unmodified in the
same fresh run that produced 83/83. No new information suggesting any regression in these areas.

---

## What I tried and could not break (this round)

- Repeated the exact fixed CRITICAL repro 3x via `--repeat-each=3` — held up every time.
- Toggled session-only ON/OFF three full cycles (check → reload → uncheck → reload → Clear all data →
  repeat) in a single test to check for any cumulative state corruption across repeated cycles — held
  up, 40 employees present after every cycle.
- Fed six additional horizonStart edge-case strings beyond last round's single repro — all
  in-scope-invalid ones correctly rejected.
- Verified the `settings` IndexedDB store is genuinely `[]`, not just "looks empty in the UI," after
  Clear all data.
- Tried an empty-app-start variant of the session-only same-session toggle (no pre-existing data at
  all) to see if the HIGH finding above was somehow an artifact of pre-existing demo data being
  present — it reproduces identically from a blank slate.

---

## Verdict recommendation (round 2)

**GO WITH FIXES**, not a clean GO. All three round-1 blocking items (the data-destroying CRITICAL, the
Clear-all leftover MEDIUM, the horizon-range LOW) are genuinely, independently confirmed fixed under
adversarial re-test, including repeat-run and additional-variant testing beyond what the Coder's own
new specs cover. The one new finding this round (HIGH: same-session toggle-off silently persists data
added during the "session only" window, contradicting this exact patch's own new UI copy) is real,
100%-reproducible, and was not caught by the Coder's own tests, but it is not destructive and does not
undo any of the three confirmed fixes above. Given this is fix loop 2 of a maximum of 3, my
recommendation is: fix the one new HIGH (likely by having `setSessionOnly(true)` snapshot or otherwise
guard in-session additions, or by having `setSessionOnly(false)` require an explicit reload rather than
calling `scheduleSave()` at all, and correcting the UI copy to match whatever behavior is actually
implemented) before final sign-off, but the pipeline is close to done — this is not another
back-to-square-one CRITICAL like last round.

---

## Files (round 2)

- New adversarial specs: `tests/specs/adversarial-session-only-round2.spec.js`,
  `tests/specs/adversarial-horizon-edge2.spec.js`.
- Re-run, unmodified, and now passing: `tests/specs/adversarial-session-only.spec.js`,
  `tests/specs/adversarial-clearall.spec.js`, `tests/specs/adversarial-horizon-edge.spec.js`,
  `tests/specs/adversarial-recheck.spec.js`.
- Full fresh run: `npx playwright test --config=pw.local.config.js` → 83/83 passed (56.0s).
- Source under test: `index.html` at commit `95e9df5`. Diff reviewed:
  `git diff HEAD~1 HEAD -- index.html` (37 lines changed: `hydrated` flag, `scheduleSave`/`persist`
  guards, `load()` branch updates, `clearAll()` no longer re-writing prefs, horizon month-range regex).
- Plan: `BUILD_PLAN.md`. Prior verdict basis: round-1 section below, `MANAGER_REVIEW.md`.

---

---

# Round 1 report (preserved, unchanged)

## Re-test pass (Fix loop 1 verification)

This is an **independent re-verification** of the Coder's fix-loop-1 commit (`fe7ec83`), done
against `MANAGER_REVIEW.md`'s NO GO verdict and `BUILD_PLAN.md` §9. I did not trust the Coder's
self-report or the new specs at face value: I re-ran the full committed suite myself, then wrote my
own adversarial specs (not derived from the Coder's) targeting the exact scenarios the Manager
flagged as under-tested, plus a few the Manager didn't ask for but that fall directly out of reading
the new code.

**Result: still NO GO.** Three of the four blocking items are genuinely fixed. The fourth
(session-only mode) is **worse than before**: the specific false-privacy-claim bug from the last
round is gone, but the fix introduces a **new, 100%-reproducible data-destroying regression** in an
adjacent, equally-realistic user flow (turn session-only ON, reload, then turn it back OFF). This is
a new CRITICAL, not a carry-over — I verified it did not exist in the pre-fix code path (the old
code never cleared `state.employees` on toggle, so the destructive `scheduleSave()` this depends on
could never fire against an empty in-memory array pointed at real data).

**Environment note (same as last round):** the sandbox proxy blocks `cdn.jsdelivr.net` and
`cdn.playwright.dev`. Testing required the same local, uncommitted Playwright config override
(`tests/pw.local.config.js`, pointing `launchOptions.executablePath` at
`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`) the Coder used. The committed
`tests/playwright.config.js` still cannot launch a browser in this sandbox — that harness-portability
gap is unchanged and remains out of scope for this pass (already logged last round).

**What I ran:**
- The full committed suite as-is: `npx playwright test --config=pw.local.config.js` → **74/74 passed**
  (all of `boot`, `calc-formulas`, `autostaff-demo`, `optimizer-ui`, `persistence`, `workbook-io`,
  `api-connector`, `perf`, `a11y`, `settings-validation`). No regressions in the previously-passing
  66 (now 74) tests. This confirms the Coder's own reported 74/74 is real, not fabricated.
- Five new adversarial spec files of my own, not copied from the Coder's:
  `tests/specs/adversarial-session-only.spec.js`, `adversarial-recheck.spec.js`,
  `adversarial-clearall.spec.js`, `adversarial-horizon-edge.spec.js` (a fifth exploratory check
  folded into `adversarial-recheck.spec.js`).
- Combined run: **80 passed, 3 failed** — the 3 failures are my new findings below, all reproduced
  more than once (the session-only one specifically re-run with `--repeat-each=2`, failed both times,
  100% reproducible, not flaky).

---

## CRITICAL

### 1. NEW REGRESSION — Turning session-only OFF after a reload silently destroys all previously-persisted data

**Status of the original CRITICAL #1:** the two specific things the Coder claimed to fix are
**genuinely fixed** — I independently verified via my own real-checkbox interaction:
- Toggling session-only ON, after data already exists, then reloading: the in-memory store now
  correctly starts empty (`employees.length === 0`), the badge is visible before and after reload,
  and `settings.sessionOnly` correctly reads back `true` after reload (previously it silently
  reverted to `false`).
- The pre-existing IndexedDB data is not deleted — it's confirmed still present via
  `ROE.db.readAll("employees")` returning the original count while the in-memory state shows 0.

This part of the fix is real, not just a passing test. **However**, the fix's own mechanism creates a
new problem the Coder did not test for, because their own new "toggle OFF" test
(`persistence.spec.js` → `"turning session-only OFF again resumes loading..."`) never reloads the
page between checking and unchecking the box — it toggles both within the same page load, where the
in-memory `state.employees` array still holds the full, non-empty dataset the whole time (nothing
clears it in-memory; only `load()` at boot decides whether to populate it). That test can only ever
pass, regardless of whether the underlying bug exists, because it never exercises the state the fix
itself introduces (an empty in-memory store with real data still sitting untouched in IndexedDB).

**What I did (own adversarial test, not derived from the Coder's spec):**
1. Loaded the app, loaded demo data (~40 employees), waited for the 400ms debounced persist.
2. Went to Data & Settings, checked the real `#set-sessionOnly` checkbox.
3. **Reloaded the page.** Confirmed (per the fix, correctly): in-memory `employees.length === 0`,
   but `ROE.db.readAll("employees")` still returns 40 — the real IndexedDB data is untouched, exactly
   as claimed.
4. Went back to Data & Settings and **unchecked** `#set-sessionOnly` (a completely ordinary "I want
   normal persistence back" action, from the state the app is actually in after step 3 — not a
   contrived state).
5. Waited 700ms (well past the 400ms debounce) for `scheduleSave()`/`persist()` to fire.
6. Reloaded again.

**What happened:** After step 5, `ROE.db.readAll("employees")` already returns **0** — the original
40 demo employees are gone from IndexedDB. After the final reload, the in-memory store also shows 0
employees. The data is permanently destroyed, not recoverable.

**What should have happened:** Turning session-only back off should, at minimum, not destroy data
that was never touched by any explicit user action (no "Clear all data", no delete). The user's
mental model at this point is "I turned a privacy switch on, then decided against it" — they have
every reason to expect their earlier data is still there, because the fix's own UI hint (added in
this same patch) literally says: *"Turning this ON takes effect immediately for new writes. Turning
it OFF resumes loading from IndexedDB on the next reload."* That promise is false — turning it off
does not "resume loading," it schedules a **write** of whatever's currently in memory (empty),
clobbering IndexedDB before the user ever gets to a reload that would have loaded the real data back.

**Root cause (read from `index.html`):**
- `ROE.store.load()` (`index.html:2249-2297`, the fixed code) starts every in-memory collection
  empty when the out-of-band `sessionOnly` preference is `true`, and never touches or reads
  IndexedDB in that case (correct, matches the claim).
- `ROE.store.setSessionOnly(on)` (`index.html:2337-2345`) does **not** call `load()` or read anything
  back from IndexedDB when `on` is `false`. It only flips `state.settings.sessionOnly`, writes the
  out-of-band preference, and — critically — calls `scheduleSave()` when turning off
  (`if (!on) scheduleSave();`).
- `scheduleSave()` → `persist()` (`index.html:2227-2247`) is a blind `DB.replaceAll("employees",
  state.employees)` (and same for every other collection) using **whatever is currently in the
  in-memory array**, with no check for "is this array actually a superset of, or at least consistent
  with, what's on disk." If the in-memory array is empty (because the browser is still in the
  post-session-only-boot state from step 3), this call **replaces** the real, non-empty IndexedDB
  object store with an empty one.
- There is no re-hydration step anywhere between "session-only turned off" and the next debounced
  save. `STORE.load()` is only ever called once, from `boot()` (`index.html:3612-3616`), never again
  during the session.

**Reproduce:** `tests/specs/adversarial-session-only.spec.js` →
`"toggle ON -> reload (in-memory empty, IDB still has data) -> toggle OFF -> wait for debounce ->
reload again: does old data survive?"`. Failed both times under `--repeat-each=2` (100%
reproducible, not a timing flake — the 700ms wait is nearly 2x the debounce).

**Impact:** This is worse than the bug it replaced. The old bug was a false privacy claim (data
that should have been purged wasn't, and the toggle silently reverted) — annoying and dishonest, but
non-destructive. This new bug **actively and silently deletes real user data** the moment a
completely ordinary "never mind, turn it back off" action is taken after any reload, with zero
confirmation, zero warning, and a UI hint that actively promises the opposite ("resumes loading from
IndexedDB"). Any user who tries the feature, reloads to confirm it worked (a very natural thing to
do, and exactly what the Coder's own persistence tests do for every other toggle), and then decides
to turn it back off loses everything with no recovery path. This blocks ship on its own, independent
of the original Critical #1 wording, and needs an architectural fix, not a one-line patch — likely
`setSessionOnly(false)` needs to call `load()` (or equivalent re-hydration) rather than
`scheduleSave()`, or `persist()` needs a guard against overwriting non-empty IndexedDB collections
with an empty in-memory array when the store was never populated this session.

---

### 2. VERIFIED FIXED — F-12 API connector now has a real, per-entity configuration UI for all 5 entities

Independently confirmed, not just re-running the Coder's spec. Own adversarial test
(`tests/specs/adversarial-recheck.spec.js`):
- Enumerated the real DOM for all 5 entities (`employees`, `projects`, `demands`, `assignments`,
  `skills`) and confirmed each has its own `enabled` checkbox, `pullPath`/`pushPath`/`responseRoot`/
  `idField` inputs, push method/mode selects, a field-mapping row editor (add/edit/remove), and its
  own Pull/Push buttons — all present with unique per-entity DOM ids/data-attributes
  (`.api-ent-enabled[data-entity="..."]` etc.), not a single shared control silently scoped to
  `employees` as before.
- Picked a **non-employee entity** deliberately (`skills`, previously completely unwired) and drove
  the entire flow through the real UI only: set base URL, checked `skills`' own Enabled checkbox,
  set its own pull path, clicked its own Pull button against a `page.route()` mock — confirmed the
  settings state (`settings.api.entities.skills.enabled === true`, `pullPath` correctly set) reflects
  real UI input, not a devtools-only bypass.

This closes the CRITICAL finding from the last round. Six previously-unreachable §9 API acceptance
bullets are now reachable by a real user for all 5 entities, not just employees.

---

## HIGH

### 3. VERIFIED FIXED — Auth-mode/baseUrl stale-closure bug is gone

Own adversarial test, driven entirely through real UI inputs (not `STORE.setSettings` calls), doing
the exact sequence the Manager's review reproduced as broken: set `#api-baseUrl` → change
`#api-authMode` to `bearer` → set `#api-token` → **also** switch `authMode` to `apiKey` and set
`#api-authHeader`, to check a third sibling field isn't clobbered either. Result: `baseUrl`,
`authMode`, and `authHeaderName` all hold their last-set values with no silent reversion. Confirmed
the fix (`updateApiField`/`updateApiEntity` reading `STORE.getState().settings.api` live rather than
a render-time-captured `s`, `index.html:3355-3364`) is real and generalizes beyond the three original
handlers to the new per-entity ones as well.

### 4. VERIFIED FIXED — Optimizer weight presets round-trip exact raw integers

Own adversarial test went a step further than the Coder's: rather than testing one preset with
non-100-summing weights, I saved **two distinct presets that normalize to the identical ratio**
(`10/10/10/10` and `20/20/20/20`, both → 0.25/0.25/0.25/0.25 once normalized) via the real sliders
and the real "Save preset" button, reloaded, and confirmed:
- Both presets exist independently in `settings.presets` after reload with their **exact, distinct**
  raw integer weights (not collapsed into one entry, not both reading back `25`).
- Selecting either preset from the real `#opt-preset` dropdown restores its own exact slider values
  (`10` for one, `20` for the other), not a shared renormalized `25`.

This is a stronger test than "does 10/10/10/10 come back as 10/10/10/10" alone, since it also proves
the storage isn't accidentally normalizing-then-only-looking-right-by-coincidence for a single case.
Confirmed fixed: `setWeightPreset` (`index.html:2373-2378`) stores raw ints, and both the save handler
(`index.html:2929-2933`) and the select handler (`index.html:2922-2928`) now agree on raw-int
semantics.

---

## MEDIUM

### 5. NEW — "Clear all data" no longer leaves the `settings` IndexedDB object store literally empty

**§9 criterion:** *"'Clear all data' requires typing `CLEAR`, then leaves every object store empty."*

As part of fixing session-only persistence, `ROE.store.clearAll()` (`index.html:2316-2332`) now
calls `DB.clearAll()` and then immediately re-writes a `"prefs"` record (`{sessionOnly, theme}`) back
into the `settings` object store, so the user's session-only choice and theme survive a full wipe.
That's a reasonable design goal, but it means the literal acceptance criterion — "every object store
empty" — is no longer true. My adversarial test confirms:

```
settings store contents after Clear all data: [{"sessionOnly":false,"theme":"dark"}]
```

**Impact:** low real-world severity (no PII, just two booleans/strings, and it's arguably the
*correct* UX so a user's privacy toggle doesn't get accidentally reset by "Clear all data") — but it
is a literal, measurable regression against a named §9 bullet, introduced by this fix pass, that
nobody flagged. Either the criterion needs an explicit amendment ("every object store holding user
data" / carve out the preference record), or the Coder should special-case `"CLEAR"` to genuinely
zero every store including the preference key and rely on the in-memory `sessionOnly` flag
resetting to default on the next natural boot. Flagging for an Architect/Manager call, not blocking
on its own, but it must be an explicit decision, not a silent side effect nobody noticed.

**Reproduce:** `tests/specs/adversarial-clearall.spec.js`.

---

## LOW

### 6. `horizonStart` validation catches shape errors but not semantic ones (e.g., "2026-13")

The bundled fix (`index.html:3288-3298`) validates with `/^\d{4}-\d{2}$/`, which correctly rejects
non-YYYY-MM garbage like `"not-a-month"` (confirmed fixed — my own test entering that value shows
the setting is rejected and reverts, with the inline error shown). It does **not** validate that the
month component is `01`–`12`. My adversarial test entered `"2026-13"` (a real month value, just out
of range) through the real input and it was accepted and stored verbatim, with no error shown:

```
horizonStart after entering 2026-13: 2026-13
```

This is a partial fix of a MEDIUM-turned-LOW issue from the last round ("horizon is silently
garbage") — the specific string the last round's Manager tried (`"not-a-month"`) is now blocked, but
the class of bug (silently-garbage horizon data) is not fully closed. Low severity because it
requires a specifically-crafted, still shape-valid input rather than any string, and the
downstream effect (month-key math on an out-of-range month) was not exercised further here since
it's a narrow edge case. Reproduce: `tests/specs/adversarial-horizon-edge.spec.js`.

### 7. CONFIRMED FIXED — CSV per-sheet export is no longer gated on XLSX CDN availability

Own adversarial test confirmed in this exact sandbox (where `window.XLSX` is genuinely absent, not
simulated): the "Export CSV (per sheet)" button (`#btn-export-csv`) remains enabled and clickable
even with `window.XLSX === undefined`. `index.html:3284-3288` confirms the `disabled` attribute was
removed from that specific button while the two genuinely-XLSX-dependent buttons keep it, plus a new
inline hint explaining why. Fixed as claimed.

### 8. Carried over, unchanged, correctly deferred (not re-litigated this pass)

Per the task instructions, these remain explicitly out of scope for this fix loop and were not
re-tested: Assignment/Skill CRUD UI absence, CSV import absence, dead `STORE.subscribe`/`notify`
pub/sub, and live CDN/XLSX/Chart.js network verification (still blocked by the same sandboxed proxy
as last round — `window.XLSX` and `window.Chart` are both still undefined here, confirmed again this
pass; no new information one way or the other). The discipline-adjacency-table plan-text asymmetry
(Architect's file, not the Coder's) is likewise unchanged.

---

## Regression pass (spot-check of the original passing 66/68→74)

Re-ran, unmodified, and confirmed still passing: `calc-formulas.spec.js` (ctxTax formulas, capacity,
determinism, sub-score breakdown, requireMinSkillLevels, mentorship pairing/compat boundaries),
`autostaff-demo.spec.js` (no over-allocation, unfilled-reason reporting, alert coverage across all 8
rules, alerts-are-derived-not-persisted), `a11y.spec.js` (labels on every panel, keyboard nav, Escape
dismissal), `perf.spec.js` (buildIndexes/alert-scan/panel-switch timings all still comfortably inside
budget), `workbook-io.spec.js` (round-trip, invalid-enum reporting, merge semantics, template no-op,
horizon-column exclusion, header remapping). Nothing here regressed as a side effect of the fix pass.
All 74 committed tests plus my 6 new confirmatory adversarial tests pass (80 total); only the 3 new
adversarial failures above are new findings.

---

## What I tried and could not break (this pass, beyond the regression spot-check)

- Tried toggling session-only on/off repeatedly within a single page load without reloading in
  between (the Coder's own tested scenario) — correctly safe, no data loss, because the in-memory
  array is never emptied by the toggle itself, only by a subsequent boot. Only the reload-in-between
  sequence is destructive.
- Tried the API stale-closure repro with a third sibling field (`authHeaderName`) in addition to the
  two the Coder tested (`baseUrl`, `authMode`) — held up, no clobbering.
- Tried two presets that normalize to an identical ratio to see if the storage fix was secretly still
  ratio-based and just happened to pass a single round-trip test — held up, both distinguishable.
- Tried a non-employee entity (`skills`) end-to-end through the real API connector UI rather than
  trusting that "employees works, so presumably the others do too" — held up correctly.

---

## Files

- New adversarial specs (all real, executed, independent of the Coder's suite):
  `tests/specs/adversarial-session-only.spec.js`, `tests/specs/adversarial-recheck.spec.js`,
  `tests/specs/adversarial-clearall.spec.js`, `tests/specs/adversarial-horizon-edge.spec.js`.
- Local, uncommitted harness override (same pattern as the Coder used, still not part of the
  committed harness): `tests/pw.local.config.js`.
- Re-run, unmodified: all of `tests/specs/*.spec.js` from the Coder's fix-loop-1 commit.
- Source under test: `index.html` (3,640 lines as of `fe7ec83`).
- Plan: `BUILD_PLAN.md`. Prior verdict: `MANAGER_REVIEW.md`.

## Verdict recommendation

**Still NO GO.** Three of four blocking items (API connector UI, preset round-trip, auth-mode stale
closure) are genuinely fixed and I could not break them with adversarial variants. Session-only mode
is not fixed so much as **moved** — the false-privacy-claim bug is gone, but a new, 100%-reproducible
data-destroying bug sits directly adjacent to it, triggered by the single most natural next action a
user would take after verifying the fix works (reload, then decide to turn it back off). This has to
go back to the Coder; it is not safe to ship. The new MEDIUM (`Clear all data` no longer literally
empties every store) and LOW (`horizonStart` month-range) findings are cheap side-fixes for the same
pass, not separate blockers.
