# TEST_REPORT.md — Weighted Decision Engine (`index.html`)

Tested by: Tester agent (rounds 1-3), orchestrator (rounds 4-5 — see notes on each). Method: static code review plus live rendering/interaction testing in a real Chromium instance (Playwright, `executablePath: /opt/pw-browsers/chromium`) loaded via `file://`, opened directly against `/home/user/ClaudeAgents/index.html` (no server). All findings below were reproduced live, not inferred from source alone.

---

# ROUND 6 STATUS (2026-08-23) — v1.1 Extension: Levers, Reasoning, and Charts

Scope: this round tests only the new "Extension: Levers, Reasoning, and Charts (v1.1)" section of BUILD_PLAN.md (E1–E11, E-A1–E-A10), as implemented in `index.html`. The core app (weighted scoring, multi-rater, exports, persistence — A1–A20) went through 5 prior rounds and is not re-litigated here beyond a light regression check on shared code paths this extension touches (export gating, `repairDecision`, results rendering).

Method: same as every prior round — live rendering/interaction testing in a real Chromium instance (Playwright, `executablePath: /opt/pw-browsers/chromium`) loaded via `file://` against `/home/user/ClaudeAgents/index.html`, no server. Driver scripts saved under `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/pwtest/` (`main.js` — lever deletion pruning + migration; `main2.js` — chart correctness + reasoning gating + markdown ordering; `main3.js` — alignment map live-update + accessible text alternatives + A15 regression + light regression; `main4.js` — lever cap, XSS/injection safety, zero-criteria edge case). All findings below were reproduced live and cross-checked against hand-computed expected values, not inferred from source alone or eyeballed from screenshots.

**Verdict up front: I could not break this extension. Every attack and edge case I tried — lever-deletion pruning under multiple simultaneous references, pre-extension session migration via both localStorage injection and the real Import file-picker, reasoning export-gating (including re-blocking when only reasoning is cleared), hand-computed bar/radar chart math against the actual rendered SVG geometry, live alignment-map updates and orphan/unserved flagging, the 8-lever cap, XSS injection into lever/criterion names rendered into SVG text, and A15 caret/focus stability while the map re-renders alongside active typing — held up exactly as specified. Self-test count matches the coder's claim (66/0). Recommend GO for this extension.**

## 1. Lever deletion pruning (E-A7) — holds under multi-reference and partial-reference attacks

Set up 2 levers ("Cost certainty" `lv1`, "Visible win" `lv2`) and 3 criteria: `c1→lv1`, `c2→lv1` (two criteria sharing one lever), `c3→lv2` (a criterion on a *different* lever, to check for over-pruning). Deleted `lv1` via the real Delete button.

- `c1`'s and `c2`'s "Serves lever" dropdowns both reset live to "No lever" (`value === ''`) — no dangling `leverId` survives.
- `c3`'s dropdown, which references the untouched `lv2`, was completely unaffected (`value === lv2's id`) — the prune is scoped correctly, not a blanket "clear all lever refs on any delete."
- Triggered an unrelated re-render (renaming `c1`) afterward and confirmed the pruned state doesn't resurrect — no stale-closure bug where the old `leverId` reappears on the next render.
- The alignment map's live text summary correctly reflected the new orphan count (`c1`, `c2` both listed as orphans) immediately after deletion, with no page reload.

No defect found here. This mirrors the existing criterion/option/rater deletion-pruning discipline exactly as E-A7 requires.

## 2. Migration of pre-extension sessions (E-A8) — both entry points clean

**Path A — direct localStorage injection** (via `addInitScript`, to avoid the app's own autosave racing the injection, per the same technique used in rounds 1–5): wrote a library object with a decision that has no `levers` array, no `reasoning` field at all, and criteria objects missing the `leverId` key entirely (not `leverId: null` — the key doesn't exist), simulating a genuinely pre-v1.1 session.
- Zero thrown page errors on load.
- Levers list renders its empty state (`#levers-empty` visible).
- `#field-reasoning` defaults to `''`.
- Every criterion's "Serves lever" dropdown defaults to "No lever" (`value === ''`).

**Path B — real Import file-picker**: wrote the same shape of pre-extension session to a `.json` file on disk and drove the actual `<input type="file" id="import-file-input">` control with `setInputFiles`.
- Zero thrown page errors.
- Same clean defaults (levers empty state, reasoning `''`, criterion leverId → "No lever") reproduced through the fully-supported import path, not just on-load migration.

Both paths matched E-A8 and E11's stated requirement exactly. Also spot-checked (via self-test assertion #20 in the shipped code, confirmed passing) that a `leverId` pointing at a lever that doesn't exist in the decision's own `levers` array (a hand-edited/foreign session, or a lever deleted before the array itself existed) also repairs to `null` rather than being left dangling — the defensive cross-validation the code comments describe.

## 3. Reasoning export gating (E-A3) — correct, including re-blocking and no regression to the original 3 fields

With reversibility set to "Hard to reverse" and all four narrative fields empty:
- Export buttons correctly `disabled`.
- Missing-items checklist lists all 4: Load-bearing assumption, **Reasoning**, revisit trigger, and (once a 2nd option exists) the top-ranked option's premortem.
- Clicking the Reasoning checklist link (`<a data-focus-target="field-reasoning">`) genuinely moves `document.activeElement` to `#field-reasoning` — not just a dead `href="#..."`.
- Filling all 4 fields (assumption, reasoning, trigger, top premortem) enables export.
- **Isolated reasoning specifically**: with the other 3 fields filled and only `reasoning` cleared afterward, export correctly re-blocks, and the missing-items list correctly shows *only* "Reasoning" — confirming reasoning is evaluated independently, not just as a batch, and confirming the pre-existing 3-field gating logic wasn't accidentally coupled or broken by adding the 4th field.
- Regression check: with reversibility = "Reversible" (not hard-to-reverse), export is correctly **not** gated by any of the four narrative fields, even when all are empty — matches the original A9 behavior.

## 4. Chart correctness (E-A5, E-A6) — hand-computed values match rendered SVG geometry exactly

Built a 3-criteria, 2-option scenario with known scores and computed expected values independently by hand (not just by calling the engine):
- Cost (lower-is-better) weight 5, Impact (higher-is-better) weight 5, Speed (higher-is-better) weight 5 — equal weights, so total = simple average of effective per-criterion scores.
- "Do Nothing" (status quo): Cost=4, Impact=6, Speed=8 → effective values (11−4)+6+8 → hand total = **7.0**.
- "Option B": Cost=8, Impact=9, Speed=3 → hand total = **5.0**.
- Both the pure `DecisionEngine.scoreOption` output and the live app's persisted `localStorage` state matched these hand-computed totals exactly.

**Bar chart (E5/E-A5):** parsed the actual rendered `<rect>` elements' `width` attributes from the DOM. Hand-computed expected widths (`fraction × barAreaW(320)`) were 224px (Do Nothing, 7.0/10) and 160px (Option B, 5.0/10) — the rendered SVG matched to sub-pixel precision (exact integer match). The recommended option is marked with a `★` prefix, bold font-weight, *and* a distinct fill/stroke (not color alone), satisfying N5.

**Radar chart (E6/E-A6):** independently hand-derived the expected (x,y) position for "Do Nothing"'s Cost axis using the documented formula (axis 0 points straight up, `frac = (effectiveValue−1)/9`, `x = centerX + frac·radius·cos(θ)`) — expected (210.0, 90.0). The actual rendered `<polygon points="...">` for that series contained a point matching (210.0, 90.0) to within 1px. Confirmed the fallback note ("Add at least 3 criteria...") renders instead of a chart with exactly 2 criteria (no degenerate 2-axis polygon), and confirmed real polygons render with exactly 3 criteria (the documented minimum). Legend differentiates each option's polygon by stroke-dash pattern in addition to color (not color alone).

No numeric or rendering discrepancy found anywhere in this section.

## 5. Alignment map correctness (E-A1, E-A2) — live updates, correct flag semantics, correct empty state

- **Zero levers**: renders the documented empty state text, zero `<svg>` elements (not an empty diagram) — matches E3's explicit requirement.
- **Lever added, no criteria assigned**: both default criteria correctly flagged as orphans (dashed red-stroke circles, `⚠ orphan` label) and the new lever correctly flagged as unserved (dashed amber-stroke circle, `⚠ unserved` label) — visually distinct fill/stroke colors confirmed via DOM attribute inspection (`#fbe9e7`/`#a5150a` for orphan criteria vs `#fff4dd`/`#e8c468` for unserved levers), satisfying the "different visual treatment, not just color" requirement.
- **Live assignment**: selecting the lever in a criterion's "Serves lever" dropdown updates the map's text summary and draws a connecting `<line>` **without any page reload** — verified by reading the DOM immediately after the `selectOption` call completes.
- **Live unassignment**: setting it back to "No lever" flips the state back to orphan+unserved live, confirming the map isn't one-way / doesn't require a full re-render trigger from elsewhere.
- **Zero criteria, 1 lever present** (edge case not explicitly listed in E-A1/E-A2 but implied by the row-layout math `Math.max(levers.length, criteria.length, 1)`): renders without crashing, text summary correctly reports "0 of 0 criteria are linked to a lever" and the lever as unserved.
- Text summary correctly distinguishes the two flag types in separate sentences ("Orphan criteria (no lever assigned): ..." vs "Unserved levers (no criteria connect to them): ...") — never conflates them.

## 6. Accessible text alternatives (E-A9) — present, non-generic, and stay in sync with data

All three (bar chart, radar chart, alignment map) expose a `<p class="visually-hidden" data-role="...">` element in the DOM (not merely an `aria-label`) with `display !== 'none'` (i.e., actually present for AT, not display:none-hidden). Content is substantive, not boilerplate — e.g. `"Bar chart: Do Nothing (status quo) at 5.5 of 10 (recommended), New option at 5.5 of 10 (recommended). The top two options are within 5% of each other — too close to call."` — not just `"chart"` or a generic label. Renamed a criterion to a unique marker string and confirmed both the alignment-map and radar-chart text alternatives updated to include the new name on the next render — they don't go stale.

## 7. A15 regression on the new inputs — no focus/caret loss

With the alignment map actively re-rendering alongside (a lever added, an extra criterion present so the map has real content to redraw on every keystroke-triggered render pass):
- Typed a 61-character sentence into `#field-reasoning` one character at a time (15ms delay) — final value matched exactly, no drops/reordering, focus remained on the textarea throughout.
- Typed a 6-character suffix into a criterion name field the same way — final value correct, focus remained on the field throughout, and the live-updating alignment map alongside it did not steal focus (confirms the coder's explicit design comment in `renderAll()` that the map "always rebuilds live" independent of the criteria list's focus-protection guard is safe in practice, not just in theory).
- Set the caret to a mid-string position (`setSelectionRange(3,3)`) and typed a character — result was `ABCZDEF` (correct insertion point), not `ABCDEFZ` (reset-to-end) — confirms caret position itself is preserved, not just that no characters are dropped.
- Zero thrown page errors during any of this.

## 8. Self-test count (E-A10)

`index.html?selftest=1` → **`SELFTEST PASS: 66 FAIL: 0`**, 0 console/page errors. Matches the coder's claim exactly. Read through the added assertions (roughly #15–24 in the file) and confirmed they cover exactly the non-trivial new pure logic E10 calls out by name: `computeLeverAlignment` orphan/unserved detection, lever-deletion pruning, pre-extension migration defaults, dangling-`leverId` repair, `barChartLayout` fraction math, `radarChartData` point-generation trig (including an exact-value check at max score and at the midpoint), `validateForExport` reasoning gating, and `toMarkdown` reasoning section placement/omission.

## 9. Additional adversarial checks (not explicitly requested but attempted, per "assume guilty until proven robust")

- **8-lever cap (E1)**: clicked "Add lever" 10 times — list correctly stops at exactly 8, the add button disables, and the cap message shows. No off-by-one.
- **XSS/injection in lever and criterion names rendered into SVG `<text>` elements**: injected `<script>alert(1)</script><img src=x onerror=alert(2)>&"'` into both a lever name and a criterion name. Zero `dialog` events fired, zero thrown errors, and the raw SVG markup showed the payload correctly HTML-entity-escaped (`&lt;script&gt;...&lt;/script&gt;`) as inert text content — no live `<script>` element was ever injected into the DOM (confirmed by querying for actual `<script>` child elements, not just string-matching the markup, to rule out a false positive from escaped text that merely contains the substring "script"). `escapeHtml`/`escapeAttr` are applied consistently to the new SVG-building code paths, same as the rest of the app.
- **Close-call bracket rendering**: confirmed (not just via code read) that when the top two options are within 5%, the bar chart actually renders 3 extra `<line>` elements forming the bracket, matching the text-alt's "too close to call" wording.

## Light regression check (per instructions, not a full re-run)

- **A9-style** (export gating with `reversibility = reversible`): correctly *not* gated, matching pre-extension behavior.
- **A19-style** (orphan score pruning): deleted a criterion that had a real score entered; confirmed via the persisted `localStorage` state that the score entry for that criterion was pruned with no dangling reference, and the criterion itself was fully removed from the `criteria` array — `repairDecision`/pruning discipline is unaffected by the extension's changes to the same function.

## Summary table

| Item | Result |
|---|---|
| E-A1 (orphan criterion flag + live line-draw on assignment) | Pass |
| E-A2 (unserved lever flag, visually distinct from orphan) | Pass |
| E-A3 (reasoning export gating, incl. isolated re-block test) | Pass |
| E-A4 (Markdown Reasoning section placement/content) | Pass |
| E-A5 (bar chart proportional to hand-computed totals, non-color recommended marker) | Pass |
| E-A6 (radar chart per-axis position matches hand-computed trig; 2-criteria fallback; 3-criteria render) | Pass |
| E-A7 (lever deletion prunes only referencing criteria, multi-ref and cross-ref scoped correctly) | Pass |
| E-A8 (pre-extension migration via localStorage injection AND Import file-picker) | Pass |
| E-A9 (real DOM text alternatives, non-generic, stay in sync with data) | Pass |
| E-A10 (66/0 self-test; A15 focus/caret unaffected by live map/chart re-renders) | Pass |
| Lever 8-cap (E1) | Pass |
| XSS/injection safety in new SVG text rendering | Pass (properly escaped) |
| Light regression: A9 (reversible case), A19 (orphan score pruning) | Pass, no regression |

## Recommendation: **GO** (for the v1.1 extension)

I attacked every priority area from the task brief — lever-deletion pruning under multi-reference and cross-reference conditions, both migration entry points, isolated reasoning-field gating, hand-computed chart math against actual rendered SVG geometry (not eyeballed), live alignment-map correctness for both flag types plus the empty state, real-DOM accessible text alternatives that stay in sync, A15 caret/focus stability with the map re-rendering live alongside active typing, the self-test count, and a light regression check on shared code paths — and found no CRITICAL, HIGH, MEDIUM, or LOW defect. The implementation matches BUILD_PLAN.md's E1–E11 requirements and E-A1–E-A10 acceptance criteria precisely, including the scope discipline the plan calls for (lever has no `weight` field, since E3's alignment map only needs identity — correctly cut, not half-implemented). This is the first round across the whole project (core app or extension) with zero findings of any severity.

---


# ROUND 5 STATUS (2026-08-23) — closing fix for the manager's final finding

The round-4-closing manager review (see the manager's verdict text preserved in the project history) independently re-verified rounds 1-4's fixes as solid, but found a fifth door into the multi-rater failure class that all four prior rounds missed: **`repairDecision()` enforced that `r_me` is always present, but never enforced that `raters` collapses to exactly one entry when `multiRater` is false.** A hand-edited or foreign session JSON with `"multiRater": false` and 2+ raters therefore still let `cellValue()` (which blends over every rater in `decision.raters` unconditionally, by design) silently factor an invisible rater's score into the ranking and the exported Markdown record — with the Raters panel hidden (since `multiRater` is false) and nothing in the UI able to reveal the discrepancy. The manager called this the same root cause as C2/C2-R2/C2-R3, just a different door, and recommended one scoped patch rather than a fourth full pipeline loop.

**This round's fix (applied and verified directly, without a further coder/tester subagent round, given the pipeline's 3-loop cap was already reached and the fix was small and precisely scoped by the manager):**

- `repairDecision()` (`index.html`, in the block right after the `r_me`-presence fix) now also collapses `raters` down to exactly `[r_me]` whenever `!d.multiRater && raters.length > 1`, before scores are filtered — so the discarded rater's scores are pruned for free by the existing `validRaterIds` check, with no separate pruning logic needed.
- The toggle-off confirmation guard (`hasOtherRaters`) was hardened from `d.raters.length > 1` to an explicit identity check (`d.raters.some(r => r.id !== 'r_me')`) per the manager's defense-in-depth recommendation, though this is now provably redundant given the invariant above always holds.
- Added self-test #14 asserting: a `multiRater:false` decision with 2 raters and conflicting scores collapses to exactly 1 rater (`r_me`) on repair/import, the other rater's score is pruned (not left dangling), and `cellValue()` reflects only `r_me`'s score afterward.
- README.md gained a one-line note (the manager's non-blocking loose end) that the in-app Print button is gated but the browser's native Ctrl+P/Cmd+P shortcut cannot be intercepted — a platform limit, not a bug.

**Verification performed (real Chromium via Playwright, same tooling as all prior rounds):**
- `index.html?selftest=1` → `SELFTEST PASS: 41 FAIL: 0` (was 36; 5 new assertions, one initial assertion had a math error caught and fixed — a test bug, not an app bug, from not accounting for a "lower is better" criterion's direction inversion).
- **Reproduced the manager's exact scenario end-to-end**: a decision with `multiRater:false`, a hidden second rater ("Hidden"), Option A scored 2/2 (Me) vs 9/9 (Hidden), Option B scored 8/8 (both raters agree). After load: `raters` in the live app state collapses to `[r_me]` only, both options' scores prune to just `r_me`'s values. The live Results panel shows **Option A: 2.00/10, Option B: 8.00/10 (Recommended)** — exactly Me's own visible input, not the blended values (which would have shown Option A at 5.5). The Markdown export's score matrix shows `Option A | 2.0 | 2.0` and `Option B | 8.0 | 8.0`, matching the UI exactly. No trace of "Hidden" or its scores survives anywhere in the app state, the UI, or the export.

**Recommendation: GO.** All CRITICAL findings across five rounds are now closed and independently re-verified end-to-end at least once each. The remaining open items are the two the manager and prior rounds already accepted as non-blocking: M1 (dual "Recommended" badge on exact ties — matches the documented tie spec) and L1 (`parseInt` truncation on adversarial decimal input — low real-world reachability). Safari-specific clipboard/blob-download behavior remains an accepted, documented residual risk (no Safari available in this environment, consistent with the plan's own risk register).

---

# ROUND 4 STATUS (2026-08-23) — closing verification after the repairDecision fix (C2-R3)

Driver scripts: `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/final_verify.js`, `final_verify2.js`, `final_verify3.js`.

**Verdict up front: C2-R3 is closed, and I could not find a fifth door into the rater-invariant failure class after specifically probing for one. Self-tests hold at 36/36. Recommend GO.**

## What was verified

1. **Self-test**: `index.html?selftest=1` → `SELFTEST PASS: 36 FAIL: 0`, zero page errors. Matches the coder's claim from the C2-R3 fix.

2. **A 4th door was specifically probed and found closed: hand-edited/corrupted localStorage, not just Import.** Round 3 verified the fix via the Import (F14) file-picker path (`fromSessionJSON`). This round targeted the other realistic entry point — a decision written directly into `localStorage['decisionEngine.v1']` (e.g. hand-edited, or corrupted by an external tool) with `multiRater: true` and a single non-`r_me` rater holding real scores, loaded via page navigation (not import) so it goes through `Store.load()` → `DecisionEngine.migrate()` → `repairLibrary()` → `repairDecision()`.
   - Confirmed directly via `window.DecisionEngine.migrate()` (the pure function, called with the raw hand-edited library): output raters are `[{id:"r_custom_hand",...}, {id:"r_me","Me",weight:1}]` — `r_me` is added alongside the existing rater, exactly as designed.
   - Confirmed live in the DOM: the rendered raters panel shows two rater rows after loading this hand-edited state.
   - Confirmed end-to-end: toggling multi-rater off on this loaded decision fires the confirmation dialog ("Turning off multi-rater mode will discard scores from the other rater(s). Continue?") — proving the in-memory state genuinely has 2 raters, not 1 — and accepting it correctly collapses to `raters: [{id:'r_me', name:'Me', weight:1}]` with the hand-crafted rater's scores discarded (a user-consented loss, not silent).
   - Root cause confirmed by code read: `repairLibrary()` maps every decision through `repairDecision()` unconditionally (`index.html:419`), and this is the single path used by both `migrate()` (every load, including hand-edited/corrupted localStorage) and `fromSessionJSON()` (import) — so the fix is structural, not path-specific.

3. **Duplicate (F10) checked for new risk — none found.** `btn-duplicate-decision`'s handler (`index.html:1182-1193`) does `JSON.parse(JSON.stringify(activeDecision))` — a structural deep-clone of an already-repaired, already-invariant-holding decision. Live check with a multi-rater decision (2 raters) duplicated: both the original and the copy retained both raters (`["r_me", "r_<custom>"]`) with no corruption. Duplicate never runs raw/unrepaired data through the model, so it cannot reintroduce this failure class.

4. **Regression spot-check (A8, A9, A15)** — all held:
   - A8: title change survived a full page reload.
   - A9: with `hard_to_reverse` set and required fields empty, all four export buttons (Markdown, JSON, clipboard, Print) reported `disabled === true`.
   - A15: typed 15 characters into a criterion name input with per-keystroke delay; final value and `document.activeElement` both correct — no focus/caret loss.

## Note on process

The round-4 tester subagent was cut off mid-investigation by an account-level API session limit (not a task failure — it had already confirmed the fix location and was moving to check `collapseRatersToSingle`, `migrate()`, and `duplicate()`, the same areas independently covered above). Rather than wait for the limit to reset, the orchestrator completed this round directly with the same tooling (Playwright + real Chromium) the tester rounds used throughout, to avoid stalling the pipeline.

## Cross-round final status

| Finding | Severity | Status |
|---|---|---|
| C1 (hidden/display CSS defeat, 7 elements) | CRITICAL | Fixed, round 2-4 regression-clean |
| C2 (multi-rater-off blending, original repro) | CRITICAL | Fixed, round 2-4 regression-clean |
| Finding 3 (Markdown export unweighted mean) | CRITICAL | Fixed, round 2-4 regression-clean |
| Finding 4 (Print bypassing export gate) | CRITICAL | Fixed, round 2-4 regression-clean |
| C2-R2 (delete-"Me"-then-collapse) | CRITICAL | Fixed, round 3-4 regression-clean |
| C2-R3 (import/hand-edit-without-r_me-then-collapse) | CRITICAL | Fixed, round 4 confirms closed via both Import and direct-localStorage doors |
| M1 (dual "Recommended" badge on ties) | MEDIUM | Accepted as-is — matches the documented tie spec (A13); product judgment call, not a defect |
| L1 (`parseInt` truncation on decimal score input) | LOW | Accepted as-is — low real-world reachability given the native number input's `step` behavior |
| L2 (dead controls in tab order) | LOW | Fixed as a consequence of the C1 fix |

**Final recommendation: GO.**

---

# ROUND 3 STATUS (2026-08-23) — final verification pass

Round-3 driver scripts are saved under `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/pw3/`. Round-2 scripts remain under `.../scratchpad/pw2/`, round-1 under `.../scratchpad/pw/`.

**Verdict up front: the coder's fix genuinely closes C2-R2 as originally reported — "Me" cannot be deleted through any UI path I could find, including forcing the disabled attribute off, dispatching raw MouseEvents, and injecting spoofed elements with matching `data-role`/`data-id` attributes into the real delegated-listener container. However, adversarial testing found that the *same underlying invariant gap* the round-2 fix patched at the UI layer was never closed at the data-model layer, and it is reachable through the fully-supported Import (F14) feature — no console tricks required, just a crafted or hand-edited session JSON file dragged through the real file picker. This reproduces total, silent, unrecoverable score loss with zero confirmation dialog, i.e. the same class of bug as C2-R2, via a different, equally realistic door. Recommend GO WITH FIXES, not GO.**

## 1. C2-R2 (delete-"Me"-then-collapse) — closed for every UI-level attack tried

Re-ran the original C2-R2 repro (`pw2/round2_C2_edge_delete_me.js`) unmodified: it now fails at step 3 (deleting "Me") with a Playwright actionability timeout, because the delete button for `r_me` is unconditionally rendered `disabled`. Good sign, but not sufficient on its own (a `disabled` attribute is trivially bypassable from a hostile/automated actor, so I went further — see `pw3/round3_C2_attack.js`):

| Attack | Method | Result |
|---|---|---|
| 1. Force-enable then real click | `btn.disabled = false` in-page, then Playwright `page.click()` (synthetic but spec-conformant mouse event) | **Me survived** — the delegated click handler on `#raters-panel` independently checks `if (id === 'r_me') return;`, so even a genuinely fired click on the real button does nothing once the id is `r_me` |
| 2. Raw `dispatchEvent(new MouseEvent('click', ...))` on the real (force-enabled) button | Bypasses Playwright's actionability checks entirely | **Me survived** — same delegated-listener guard catches it |
| 3. Spoofed element injected into `#raters-panel` with `data-role="delete-rater"` and `data-id="r_me"`, then clicked | Simulates an attacker/extension injecting a fake control matching the real DOM contract | **Me survived** — the delegated listener only looks at `dataset.id`, and since that's `'r_me'` regardless of which physical element carries it, the same guard fires |
| 4. Checked for an exposed mutation surface (`window.App`, `window.Store`, etc.) that could set `decision.raters` directly | `window.App` and `window.Store` are not exposed globally (only `DecisionEngine` and `UI` are); no direct in-memory mutation path found from the console | N/A — no additional surface found |

Conclusion: the guard is implemented at the right layer (the delegated event handler, not just a disabled attribute or the render function), so it holds under everything I could throw at the DOM/event layer. **C2-R2 as originally scoped is fixed and robust.**

## 2. NEW FINDING — C2-R3 (CRITICAL, still open): the exact same silent-data-loss path is reachable via Import, because the fix was applied at the UI layer, not the data model

**What I did:** Rather than trying to delete "Me" through the UI (now correctly blocked), I asked whether the invariant "raters always contains r_me" is enforced anywhere below the UI — i.e., in `repairDecision()`, which is the function that sanitizes every decision loaded from storage *or from an imported file*. Reading it (index.html, `repairDecision`):

```js
var raters = Array.isArray(d.raters) ? d.raters.map(repairRater) : [];
if (!raters.length) raters = [{ id: 'r_me', name: 'Me', weight: 1 }];
```

This only backfills the implicit `r_me` rater when the `raters` array is **completely empty**. If `raters` is non-empty but contains no `r_me` entry at all (e.g. `[{id:'r_custom_only', name:'Rater 2', weight:1}]`), it passes through completely unchanged — `repairDecision` never checks "does this contain r_me specifically," only "is this array non-empty." This function runs on every `fromSessionJSON` call (i.e. every import) and every `migrate()` call (i.e. every page load), so it is the actual invariant-enforcement point for the data model — and it doesn't enforce the invariant the round-2 fix assumes always holds.

I crafted a session-JSON file with `multiRater: true`, `raters: [{id:'r_custom_only', name:'Rater 2', weight:1}]` (no `r_me` at all), and real scores keyed under `r_custom_only`, then imported it through the real `<input type="file">` picker (F14's actual, supported import path — no console/devtools involved).

**What happened (`pw3/round3_C2_import_bypass2.js`):**
1. Import succeeds without error, appended as "Imported Evil Decision (imported)" per spec.
2. Switching to the imported decision confirms the persisted state exactly as crafted: `multiRater: true`, `raters: [{id:'r_custom_only', ...}]`, real scores intact (`o1.c1.r_custom_only: 7`, etc.). The Multi-rater checkbox shows checked, the matrix cell shows "7", everything renders as a normal, healthy multi-rater decision.
3. I then clicked the Multi-rater toggle to turn it off. **No `confirm()` dialog fired** — the guard `var hasOtherRaters = d.raters.length > 1;` is `false` because there is exactly one rater (it just isn't `r_me`), which is the identical logic gap C2-R2 identified in round 2, just reached by a different route.
4. `collapseRatersToSingle(d)` ran unconditionally, found no rater with `id === 'r_me'`, fabricated a brand-new empty `{id:'r_me', name:'Me', weight:1}`, and `pruneScores` deleted every score keyed under `r_custom_only` — i.e. **all of them**.
5. Net effect: the cell that showed "7" a moment earlier is now blank, `localStorage`'s `scores` for that decision is `{}`, and the user received **zero warning of any kind** before real, previously-persisted data (it survived an actual export → reimport round trip, so it's exactly as "real" as any other data in the app) was silently destroyed.

**Reproduction:** `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/pw3/round3_C2_import_bypass2.js`. Steps:
1. Craft (or hand-edit a real exported) session JSON: set `"multiRater": true`, `"raters": [{"id":"r_something_not_r_me","name":"Rater 2","weight":1}]`, and populate `scores` under that rater id.
2. Import via the app's real "Import session JSON" file input.
3. Switch the library selector to the imported decision (state confirmed correct and fully functional at this point — nothing about the import itself is flagged as invalid).
4. Turn the Multi-rater toggle off. **No confirmation dialog appears.**
5. Observe the previously-populated cells are now blank and `scores` is `{}` in `localStorage`.

**Why this is a distinct, still-open finding and not just "C2-R2 again":** the round-2 fix closed the *specific mechanism* reported (deleting the seeded `r_me` rater through the Raters panel) by adding a UI-level guard (disabled button + delegated-handler check on `id === 'r_me'`). That fix is real and I could not defeat it (see section 1). But it operates entirely on the assumption that `r_me` is always present in `decision.raters`, an assumption that is true for any decision *created and only ever edited inside this session's UI*, but is **not** enforced by `repairDecision()`, which is the actual gatekeeper for anything coming from `localStorage` or from an imported file. Since F14 (Import) is a first-class, spec-required feature — not a hostile console trick — and nothing in `fromSessionJSON`'s validation rejects a raters array that's non-empty but `r_me`-less, this is a fully realistic path a real user can hit (e.g. hand-editing an exported JSON, receiving one from an older/different build, or any future schema-migration bug that drops the `r_me` entry) and reach the identical silent-data-destruction outcome C2-R2 was supposed to eliminate entirely.

**Why CRITICAL, not HIGH:** identical severity reasoning to C2-R2 — real, deterministic, zero-warning, total loss of previously-real (export-round-tripped) scored data, through a documented, user-facing feature (Import), with no error, no dialog, and no way to recover once it happens (the data is gone from `localStorage` the moment the debounced save fires).

**Fix direction (for the Coder, not applied by me):** Push the invariant down to where it's actually enforced — `repairDecision()` should guarantee `r_me` is present in `raters` whenever `raters` is non-empty too, not only when it's empty (e.g., if no entry has `id === 'r_me'`, either inject one alongside the existing raters, or re-key the *first* existing rater to `id: 'r_me'` while preserving its name/weight/scores — whichever preserves the most data). Separately, and more robustly: the toggle-off guard and `collapseRatersToSingle` should stop trusting `raters.length > 1` as a proxy for "is there anything to lose" — as flagged in round 2, the correct condition is "does the sole remaining rater already have the canonical `id === 'r_me'` identity," checked directly, so this whole class of bug (present-day and any future route into it) closes at the root rather than needing a new patch every time a new door to a non-`r_me`-only-rater state is found.

## 3. Normal multi-rater collapse (2 raters, both scored) — no regression

`pw3/round3_normal_collapse.js`: enabled multi-rater, added a rater, scored Me=9 and Rater2=3 on the same cell.
- **Cancel path**: dialog fires with the expected text, dismissing it leaves the toggle checked and both raters (`r_me` + the added rater) fully present.
- **Confirm path**: dialog fires, confirming collapses to exactly `raters: [{id:'r_me', ...}]`, the visible cell shows **9** (Me's own value, not Rater2's 3 and not a blend), correct after a full page reload, and the exported session JSON (`DecisionEngine.toSessionJSON`) contains only `r_me` in both `raters` and `scores` — no orphaned keys. Matches round-2's findings exactly; no regression.

## 4. Other rater management (add / rename / reweight / delete non-Me) — all work normally

`pw3/round3_rater_mgmt.js`: added 2 extra raters (3 total), renamed one, changed its weight via the range input (persisted correctly to `localStorage`), deleted it (leaves 2), deleted the last non-Me rater (leaves exactly `[r_me]`), and confirmed that with only `r_me` left, its delete button is present but `disabled` (consistent with the invariant, not a dead/missing control). All operations behaved exactly as expected, no side effects on unrelated raters or scores.

## 5. Self-test harness

`index.html?selftest=1` → **`SELFTEST PASS: 32 FAIL: 0`**, 0 console/page errors. Matches round 2's count exactly (no new self-tests were added for this round's fix, and none regressed).

## 6. Full A1–A20 regression sweep

Re-verified every acceptance criterion live (not just the ones touched by the round-2/round-3 fixes). Scripts: `pw3/round2_regression.js` (reused verbatim), `pw3/round3_sweep2.js`, `round3_sweep2b_tie.js`, `round3_sweep2c_closecall.js`, `round3_sweep3.js`, `round3_sweep4.js`, `round3_caps2.js`, `round3_print_check.js`, `round3_L1.js`.

| Criterion | Result |
|---|---|
| A1/A2 (no console errors, no network requests, fresh load) | 0 console errors, 0 non-`file://` network requests |
| A3 (status-quo seeded) | Confirmed checked on fresh load |
| A4 (normalized % sums to 100.0) | Confirmed via existing round-2 script logic (weights 5/5/8 → sums to 100.0%) |
| A5 (hand-computed totals) | 7.00 / 7.25 exactly, matching hand calc |
| A6 (direction flip) | Status-quo total correctly flips 7.00 → 4.50 when Cost direction flips |
| A7 (unscored → midpoint) | "1 of 2 criteria unscored" badge shown, still ranked using 5.5 fallback |
| A8 (persistence across reload) | Title survives a real page reload |
| A9 (export gating + focus links) | Exactly 3 missing items listed; clicking first link focuses `#field-assumption` |
| A10 (Markdown content) | Contains title, recommendation section, criteria/weights, options/premortems |
| A11 (import round-trip, fresh profile) | Real download → real file-picker import into a cleared profile: appended as new decision with `(imported)` suffix, new id, original decision untouched |
| A12 (weighted multi-rater blend) | Covered by section 3 above; math unaffected by the fix |
| A13 (ties / close-call boundary) | Exact tie → both `T1`, status-quo listed first; 10% and exactly-5% margins correctly do **not** trigger close-call (strict `<0.05`); confirmed no regression from round 1/2's boundary self-tests |
| A14 (self-test count) | `PASS: 32 FAIL: 0` — see section 5 |
| A15 (typing/caret stability) | Character-by-character typing into title field: value and focus intact, no drops |
| A16 (380px responsive) | `scrollWidth === clientWidth` (380/380), no overflow |
| A17 (keyboard flow) | Spot check: Tab moves focus, no thrown errors |
| A18 (corrupt localStorage recovery) | Genuinely corrupt load (via `addInitScript` to avoid the `beforeunload` self-healing flush noted in round 1): `#corrupt-banner` shown with `display:flex` and correct text, backup key `decisionEngine.v1.corrupt.<ts>` present with a byte-for-byte match of the original corrupt string |
| A19 (orphan pruning) | Deleting a scored criterion and a scored option both correctly remove their entries from `scores`; no orphaned keys in the live store |
| A20 (print output) | Corrected methodology from an earlier mis-check in this round (I initially checked `display`, but the print CSS uses `visibility: hidden` on `body *` plus `visibility: visible` scoped to `#markdown-preview` — checking the right property confirms `#app-header`, `#btn-print`, `#matrix-container`, `#raters-panel` are all `visibility:hidden` under print media, and `#markdown-preview` is `visibility:visible`, exactly as designed) | Confirmed correct, no regression |
| 12-item caps (criteria/options) | Both cap at exactly 12, cap message shows at 12 not before, `Add` buttons `disabled`, and a forced `.click()` on the disabled button via `page.evaluate` has no effect |
| XSS | `<img src=x onerror=alert(1)>` in the title field stored/rendered as inert text, zero dialogs fired |
| L1 (decimal truncation) | Unchanged: `"3.7"` still stores as `3` via `parseInt` truncation — confirmed still present, still LOW, untouched code path as predicted in round 2 |
| M1 (dual "Recommended" badge on exact ties) | Unchanged: confirmed still present via the A13 tie re-test (two `T1` cards both show "Recommended") — still MEDIUM/judgment call as before |

I did not find any regression anywhere in this sweep. Everything that passed in rounds 1–2 still passes in round 3.

## Summary of round-3 status

| Item | Round-1 | Round-2 | Round-3 (final) |
|---|---|---|---|
| C1 (7 hidden/display elements) | CRITICAL | FIXED | **FIXED — reconfirmed, no regression** |
| C2 (multi-rater-off blending, original scenario) | CRITICAL | FIXED | **FIXED — reconfirmed, no regression** |
| C2-R2 (delete-"Me"-then-collapse via UI) | *new in round 2* | CRITICAL — open | **FIXED — closed against every UI/DOM-level attack tried (force-enable, raw dispatchEvent, spoofed element)** |
| C2-R3 (same invariant gap, reached via Import instead of delete) | — | — | **NEW — CRITICAL — open** |
| Finding 3 (Markdown unweighted mean) | noted | FIXED | **FIXED — no regression** |
| Finding 4 (print bypassing export gate) | noted | FIXED | **FIXED — no regression** |
| A14 (self-test count) | skipped | PASS 32/0 | **PASS 32/0 — reconfirmed** |
| F13b (clipboard tiers) | not tested | all 3 verified | not re-tested this round (untouched code, no reason to suspect regression) |
| M1 (dual "Recommended" badge on ties) | MEDIUM, judgment call | not re-tested | **Reconfirmed present, unchanged — MEDIUM, accepted-as-is (judgment call, not a defect per spec)** |
| L1 (decimal truncation on hostile score input) | LOW | not re-tested | **Reconfirmed present, unchanged — LOW, open but low-impact** |
| L2 (dead tab-order controls) | LOW, consequence of C1 | FIXED | **FIXED — no regression (not independently re-walked this round, but C1's underlying CSS rule is confirmed still in place and untouched)** |

## Final overall recommendation: **GO WITH FIXES**

Three full rounds in, the application's core engine, persistence, export/import, gating, accessibility, and responsive behavior are all solid — I was unable to find any new defect anywhere outside the multi-rater collapse invariant across three rounds of adversarial testing on the calculation layer, self-tests, print/export/import, caps, XSS, and keyboard/focus handling. The coder's round-3 fix for C2-R2 is well-built (enforced at the delegated-event-handler layer, not just a disabled attribute) and I could not defeat it through any DOM-level attack. However, the fix treated the symptom (a UI action that could produce a non-`r_me`-only rater list) rather than the root cause (nothing below the UI enforces that `r_me` is always present in `raters`), and the Import feature — a fully supported, spec-required path (F14), not a hostile workaround — reaches the identical unguarded `collapseRatersToSingle`/`pruneScores` code path and produces the identical outcome: total, silent, unwarned loss of real scored data. This is not a hairline edge case; it will happen to any user who hand-edits an exported JSON (a natural thing to do, since the format is human-readable) or receives one that's slightly non-conformant, and it fails in the worst possible way — no error, no dialog, just gone.

Recommend one more targeted pass from the Coder scoped narrowly to: (1) `repairDecision()` guaranteeing `r_me`'s presence whenever `raters` is non-empty, not just when it's empty, and (2) changing the toggle-off guard and `collapseRatersToSingle` to check "is the sole remaining rater's id `r_me`" directly rather than `raters.length > 1`, so this class of bug cannot resurface through some other not-yet-found door. Given the fix is narrow, well-understood, and every other area of the app has now held up across three rounds, I'd expect this to be the last blocking item before GO.

## Final status table — every CRITICAL/HIGH/MEDIUM/LOW finding across all 3 rounds

| Finding | Severity | Round found | Final status |
|---|---|---|---|
| C1 — 7 hidden/display elements permanently visible | CRITICAL | 1 | **Fixed** (round 2, reconfirmed round 3) |
| C2 — multi-rater-off blends hidden rater into visible cell/total | CRITICAL | 1 | **Fixed** (round 2, reconfirmed round 3) |
| C2-R2 — deleting seeded "Me" rater then toggling off silently wipes data, no dialog | CRITICAL | 2 | **Fixed** (round 3, verified against 4 independent attack vectors) |
| C2-R3 — importing a crafted/edited session JSON whose sole rater isn't `r_me` reaches the identical silent-wipe outcome | CRITICAL | 3 | **Open** — recommend one more fix pass before GO |
| Finding 3 — Markdown export used unweighted mean instead of `cellValue` | (unranked, real defect) | 1 | **Fixed** (round 2, reconfirmed round 3) |
| Finding 4 — Print button bypassed export gating | (unranked, real defect) | 1 | **Fixed** (round 2, reconfirmed round 3, re-tried 3 bypass methods again this round with no new attempts needed as none succeeded previously) |
| A14 process gap — self-test count never actually run in round 1 | (process gap) | 2 | **Closed** — 32/0 confirmed in rounds 2 and 3 |
| M1 — tied rank-1 options both show "Recommended" badge | MEDIUM | 1 | **Accepted-as-is** — judgment call per spec's tie-handling rule (A13), not treated as a defect by the coder across 3 rounds, reconfirmed unchanged |
| L1 — decimal score input truncated via `parseInt` instead of rounded/rejected | LOW | 1 | **Open, accepted-as-is** — unchanged across 3 rounds, low real-world impact (native `type=number step=1` makes it hard to trigger without deliberate scripting) |
| L2 — dead tab-order controls at session start | LOW | 1 | **Fixed** (round 2, direct consequence of C1's fix, reconfirmed round 3 via unchanged CSS) |

---

# ROUND 2 STATUS (2026-08-23)

Round-2 driver scripts are saved under `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/pw2/` if reruns are needed. Round-1 scripts remain under `.../scratchpad/pw/`.

**Verdict up front: 3 of the 4 claimed fixes hold up completely under adversarial re-testing. The 4th (C2, multi-rater collapse) fixes the exact scenario originally reported but introduces a new, narrower CRITICAL silent-data-loss edge case that was not covered by the coder's self-tests. Recommend GO WITH FIXES, not GO, until the new finding (C2-R2) is addressed.**

## Fix-by-fix results

### C1 (hidden/display CSS bug) — **FIXED, no regressions found**
Verified the global `[hidden] { display: none !important; }` rule (index.html line 28) live for all 7 previously-affected elements:

| id | Fresh load | Real trigger fired | Result |
|---|---|---|---|
| `#corrupt-banner` | hidden, `display:none`, `offsetHeight:0` | Injected corrupt `localStorage` + reload | Shown (`display:flex`, real backup-key text), Dismiss button now actually hides it (`display:none` after click) |
| `#quota-banner` | hidden | Monkeypatched `localStorage.setItem` to throw on save | Shown, save-status correctly flips to "Not saved — see warning" |
| `#import-errors` | hidden | Imported a malformed JSON file via the real file input | Shown with the real parse-error text |
| `#criteria-cap-msg` | hidden | Added criteria up to 12 | Shown at exactly 12, not before |
| `#options-cap-msg` | hidden | Added options up to 12 | Shown at exactly 12, not before |
| `#close-call-banner` | hidden | Scored two options to an 8.0 vs 7.9 total (1.25% margin) | Shown correctly, hidden again when margin is wide |
| `#export-gating` | hidden | Set Hard-to-reverse with empty required fields | Shown with the correct missing-items list; correctly hides again once all three fields are filled |

Also reconfirmed **L2** (dead tab-order controls) is resolved as a direct consequence: on a fresh session, the second Tab stop after the skip-link is now `#decision-title-input`, not the phantom "Dismiss"/"Export session JSON" controls.

I could not break C1. Tried: rapid toggling of trigger conditions, re-triggering after dismiss, combining multiple banners active simultaneously (export-gating + close-call-banner both showed correctly side-by-side with correct independent visibility).

### C2 (multi-rater-off blending hidden raters) — **PARTIALLY FIXED — original bug gone, but a new CRITICAL silent-data-loss edge case exists**

**What now works correctly (verified live):**
- Turning multi-rater off with 2+ raters present now shows `window.confirm('Turning off multi-rater mode will discard scores from the other rater(s). Continue?')`.
- **Cancel path**: toggle checkbox reverts to checked=true, raters panel stays visible, both raters and their scores remain completely intact (verified rater count stays 2, no `UI.onStateChange()` side effects fire).
- **Confirm path**: `decision.raters` collapses to exactly `[{id:'r_me', ...}]`, all non-`r_me` score entries are pruned, and — critically — the visible score-cell now shows **Me's own value** (verified: scored Me=10/Rater2=2 with weights 1/3 on a higher-is-better criterion, blended readout correctly showed 4.0 before collapse, and after collapse the cell showed "10", not "2" or "4" — the original bug's symptom is gone).
- Survives a full page reload: cell value and toggle state both correct after reload.
- Exported session JSON after collapse contains `"raters":[{"id":"r_me",...}]` only, and `scores` contains no orphaned non-`r_me` keys.
- Self-test 11 (new, added by the coder) exercises this path at the engine level and passes.

**New finding — C2-R2 (CRITICAL): silently wipes rater data with *no* confirmation dialog if the surviving rater's id isn't literally `r_me`**

**What I did:** Enabled multi-rater, added "Rater 2", scored a cell as "Rater 2" = 7 (never scored as "Me" at all), then **deleted the original "Me" rater** (deleting is allowed as long as ≥1 rater remains, and deleting "Me" is not specially protected). This leaves `decision.raters` as a single, non-`r_me`-id rater ("Rater 2") holding real scored data. I then turned multi-rater mode off.

**What happened:**
- No `confirm()` dialog fired at all — the code's dialog guard is `var hasOtherRaters = d.raters.length > 1;`, which is `false` here because there is only one rater left (Rater 2), even though that one rater is not the implicit "Me".
- `collapseRatersToSingle(d)` then ran unconditionally: it looks for a rater with `id === 'r_me'`, finds none, and falls back to a **brand new** `{id:'r_me', name:'Me', weight:1}` object — discarding "Rater 2" entirely, including its id.
- `pruneScores(d)` then deletes every score whose rater id isn't in the new `[r_me]` roster — which is *all* of them, since every existing score was keyed under "Rater 2"'s original id.
- Net effect: the cell that showed "7" a moment before now shows **empty ("N/A")**, the score is gone from `localStorage`, and the user got **zero warning** that this would happen — worse than the original C2 bug in one respect, because the original bug at least kept "Me"'s data intact; this path deletes the *only* data that existed, silently, without even the confirm dialog the fix otherwise added.

**Reproduction:** `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/pw2/round2_C2_edge_delete_me.js`. Steps:
1. New decision → enable Multi-rater mode → Add rater ("Rater 2").
2. Switch "Scoring as" to Rater 2, score any cell (e.g. 7).
3. Delete the "Me" rater from the Raters panel (leaves only "Rater 2", which now has id `r_...` not `r_me`).
4. Turn multi-rater mode off. **No confirmation dialog appears.**
5. Observe the previously-scored cell is now blank, and `localStorage`'s `scores` object for that decision is now `{}`.

**Why CRITICAL, not HIGH:** It is a real, deterministic, easily-triggered workflow (delete the default rater, keep a custom one — nothing prevents this, and multi-rater's whole premise is that "Me" isn't necessarily the important rater) that causes **total, silent, unrecoverable loss of scored data** with **no warning of any kind**, which is a strictly worse outcome than the bug this round's fix was meant to close. The guard condition (`raters.length > 1`) conflates "are there multiple raters to warn about" with "is the sole remaining rater already the canonical single-rater identity" — those are not the same thing once a user can delete the seeded `r_me` rater.

**Fix direction (for the Coder, not applied by me):** The dialog condition and the collapse logic both need to key off "does collapsing lose any data / change any rater identity," not `raters.length > 1`. Concretely: fire the confirm whenever `d.raters.length > 1` **or** the sole remaining rater's id isn't `r_me`; and `collapseRatersToSingle` should preserve the sole remaining rater's *scores* under the canonical `r_me` id (re-keying rather than discarding) when there's exactly one rater left, regardless of its original id — or, more conservatively, just refuse to silently drop it and always route through the same confirm-or-preserve path used for the ≥2-rater case.

### Finding 3 (Markdown export unweighted-mean bug) — **FIXED, confirmed**
`toMarkdown`'s score matrix now calls `DecisionEngine.cellValue` (index.html line 620). Live-verified with weights 1 (Me) and 3 (Rater 2), scores 10 and 2 on a higher-is-better criterion: UI blend readout showed "Blended: 4.0", and the exported Markdown's `## Full score matrix` table showed the same **4.0** — not the old incorrect unweighted mean of 6.0. Self-test 12 (new) also asserts this at the engine level and passes.

### Finding 4 (Print bypassing export gate) — **FIXED, confirmed, tried to force it 3 ways**
With reversibility = Hard to reverse and required fields empty, `#btn-print` is now in the same disabled group as Markdown/JSON/clipboard (`[EL.btnExportMd, EL.btnExportJson, EL.btnCopyClipboard, EL.btnPrint].forEach(...)`), and the click handler itself re-validates before calling `window.print()`. I instrumented `window.print` and tried to force the click three ways while the button was disabled:
1. Playwright's `page.click()` (real synthetic mouse event, actionability-checked) — correctly refused to click a disabled element (timed out as expected).
2. `document.getElementById('btn-print').click()` from the console — disabled elements don't dispatch `click` per HTML spec — `window.print` was **not** called.
3. `element.dispatchEvent(new MouseEvent('click', ...))` directly — same result, **not** called.

Once the required fields were filled, the button correctly became enabled and a real click did call `window.print()` exactly once. Could not bypass the gate.

## Process gaps closed

### A14 — self-test count, actually run this time
`index.html?selftest=1` renders **`SELFTEST PASS: 32 FAIL: 0`** — confirmed live via Playwright, 0 failures listed. Matches the coder's claim of 32.

### Clipboard export (F13b) — all three tiers tested live
- **Tier 1** (`navigator.clipboard.writeText`): granted clipboard permissions in a real Chromium context, clicked Copy, then independently read back `navigator.clipboard.readText()` — content matched the exported Markdown (`starts with "# "` confirmed true), and `#copy-status` showed "Copied to clipboard."
- **Tier 2** (`document.execCommand('copy')`): stubbed `navigator.clipboard` to `undefined` before load, clicked Copy — `#copy-status` still showed "Copied to clipboard." and the fallback textarea correctly stayed hidden (execCommand succeeded in this Chromium build).
- **Tier 3** (last-resort textarea reveal): stubbed both `navigator.clipboard` to `undefined` **and** `document.execCommand` to always return `false`, clicked Copy — `#copy-status` correctly changed to "Press Ctrl+C to copy (automatic copy unavailable)." and `#clipboard-fallback-textarea` became visible, focused, text-selected, and populated with the correct Markdown content.

All three tiers work exactly as designed. Could not break the clipboard fallback chain.

## Regression pass (A5–A9, A15, A17) — all held, no regressions

- **A5** (hand-computed totals): 2-criteria/2-option matrix, one cell deliberately left unscored — totals matched hand calculation exactly (7.00 and 7.25).
- **A6** (direction flip): flipping "Cost" from lower→higher-is-better correctly changed the status-quo option's total from 7.00 to 4.50 (recomputed from raw scores, not cached).
- **A7** (unscored-cell handling): the option with 1 unscored criterion correctly showed the "1 of 2 criteria unscored" badge and still ranked using the 5.5 midpoint fallback.
- **A8** (persistence): a title change survived a full page reload.
- **A9** (export gating + focus links): Hard-to-reverse with empty fields correctly listed exactly 3 missing items with working links; clicking the first link correctly moved focus to `#field-assumption`.
- **A15** (typing/caret stability): typed a 26-character string character-by-character with delays into the title field — value and focus were both intact afterward, no drops or caret jumps.
- **A17** (keyboard flow, spot check only per instructions): quick keyboard interaction sanity check, no console errors, focus moved as expected.

Nothing regressed from the shared code paths (`pruneScores`, render logic, button gating) that the C1/C2 fixes touched.

## Summary of round-2 status

| Item | Round-1 status | Round-2 status |
|---|---|---|
| C1 (7 hidden/display elements) | CRITICAL | **FIXED** |
| C2 (multi-rater-off blending) — original scenario | CRITICAL | **FIXED** |
| C2-R2 (multi-rater-off after deleting "Me") | *new in round 2* | **CRITICAL — open** |
| Finding 3 (Markdown unweighted mean) | (unranked, noted) | **FIXED** |
| Finding 4 (Print bypassing gate) | (unranked, noted) | **FIXED** |
| A14 (selftest count) | skipped in round 1 | **Run: PASS 32 / FAIL 0** |
| F13b (clipboard tiers) | not tested in round 1 | **All 3 tiers verified working** |
| M1 (dual "Recommended" badge on ties) | MEDIUM, judgment call | Not re-tested this round (untouched by the fixes); presumed unchanged |
| L1 (decimal truncation on score input) | LOW | Not re-tested this round; presumed unchanged (untouched code path) |
| L2 (dead tab-order controls) | LOW, consequence of C1 | **FIXED** (confirmed: 2nd Tab stop is now `#decision-title-input`) |

**Recommendation: GO WITH FIXES.** All four originally-requested fixes were genuinely applied and 3 of 4 are fully solid under adversarial re-testing. However, the C2 fix's own guard condition (`raters.length > 1`) introduces a new CRITICAL silent-data-loss path that is easy to trigger (delete the default rater, keep a custom one, turn multi-rater off) and strictly worse than the original bug because it deletes real data with zero warning. This should go back to the coder for one more pass before GO.

---

# ROUND 1 REPORT (original, kept for context)

Verdict up front (round 1): the calculation engine, persistence, gating, export/import, keyboard flow, and responsive layout are all solid and match the BUILD_PLAN spec closely — I could not break the math, the focus/caret handling (A15), or the keyboard-only flow (A17). But there are two CRITICAL defects that undermine trust in the app on literally every session, plus a handful of lower-severity issues.

---

## CRITICAL

### C1. Every "hidden" banner/message that also carries `.banner` or `.badge-warning` is permanently visible, regardless of `hidden` state — confirmed on 7 elements, not just the 1 originally spotted

**[ROUND 2: FIXED — see "ROUND 2 STATUS" above for live re-verification of all 7 elements.]**

**What I did:** Loaded a brand-new session (cleared profile) and inspected every element carrying the `hidden` attribute via `getComputedStyle(...).display` and `offsetHeight`. Also toggled the underlying JS state (dismiss button, quota error injection, export gating) to confirm the `hidden` attribute *is* being set/cleared correctly by the JS, but has no visual effect.

**Root cause:** `.banner { display: flex; ... }` and `.badge-warning { display: inline-block; ... }` are author-origin rules with no `:not([hidden])` guard. An author-origin `display` declaration always beats the UA's `[hidden] { display: none }` rule regardless of source order or specificity, so any element combining one of these classes with the `hidden` attribute never actually hides.

**Elements confirmed affected (7 total)**, all visible with real, often misleading content on a pristine, freshly-created decision (2 seeded criteria, 1 seeded option, nothing scored):

| id | class | On fresh load shows |
|---|---|---|
| `#corrupt-banner` | `banner banner-warning` | An empty amber banner with a live "Dismiss" button, even though no corruption occurred |
| `#quota-banner` | `banner banner-danger` | "Changes are no longer being saved — export your decision now." even though saving is working fine |
| `#import-errors` | `banner banner-danger` | An empty red banner under the header |
| `#criteria-cap-msg` | `badge-warning` | "Maximum of 12 criteria reached." with only 2 criteria present |
| `#options-cap-msg` | `badge-warning` | "Maximum of 12 options reached." with only 1 option present |
| `#close-call-banner` | `banner banner-info` | "Too close to call…" shown simultaneously with the *correct* "Not enough data yet" message, on a decision with no scores at all |
| `#export-gating` | `banner banner-warning` | An empty amber banner in the Decision record section even when exports are fully enabled |

(`#status-quo-nudge`, `#criteria-empty`, `#options-empty`, `#raters-panel`, `#clipboard-fallback-textarea` do **not** have this bug — their classes don't set `display`, so `hidden` works correctly there. This confirms the bug is specifically scoped to `.banner` and `.badge-warning`.)

**Reproduction:**
```
Open index.html fresh (or with any state). Run in the console:
['corrupt-banner','quota-banner','import-errors','criteria-cap-msg','options-cap-msg','close-call-banner','export-gating']
  .forEach(id => { const el = document.getElementById(id); console.log(id, el.hidden, getComputedStyle(el).display); });
```
All 7 print `true` for `hidden` but a non-`none` `display`.

**Downstream effects verified live:**
- The "Dismiss" button on the corrupt-data banner is a dead control: clicking it correctly sets `hidden = true` in the DOM (verified via JS), but the banner never disappears, because CSS still forces `display: flex`.
- Tab order on every fresh page load starts with two phantom, always-reachable controls ("Dismiss" and "Export session JSON" from the corrupt/quota banners) before the user ever reaches the actual header controls — confirmed via full keyboard Tab walk.
- The false "Changes are no longer being saved" banner is a trust-destroying false negative: it appears on a session where saving is working perfectly, and there is no way to distinguish it from a real quota failure (which also cannot be dismissed for the same reason, and is now indistinguishable from the permanent false positive).
- The false "Too close to call" banner appears even with zero scored data / insufficient options, i.e. the app cannot represent "no data" and "ambiguous top-2" as different, mutually exclusive states, even though they are.
- `#export-gating` renders an empty flex box permanently in the Decision Record section even when exports are enabled and there is nothing to show.

**Why CRITICAL, not just HIGH:** This is not an edge case — it reproduces on literally every load of the app, in every browser that honors CSS specificity/origin rules correctly (all evergreen browsers per N8), with zero user action required. It actively misrepresents save-safety and data-completeness state, the two things N7 says must never fail silently. A real user opening this app for the first time sees four false alarms and one dead "Dismiss" button before touching anything.

**Fix direction (for the Coder, not applied by me):** scope the display declarations to `:not([hidden])`, e.g. `.banner:not([hidden]) { display: flex; ... }` and `.badge-warning:not([hidden]) { display: inline-block; ... }`, or add a global `[hidden] { display: none !important; }` rule.

---

### C2. Turning multi-rater mode OFF does not return the app to a true single-rater state — it keeps silently blending scores from now-invisible raters into the ranking, while the visible score-matrix cell shows a different (wrong) raw value

**[ROUND 2: FIXED for the originally-reported scenario, but see C2-R2 in "ROUND 2 STATUS" above for a new, narrower CRITICAL edge case introduced by the fix.]**

**What I did:** Enabled multi-rater mode, added a second rater with a different weight, scored one cell as "Me" = 10 and the same cell as "Rater 2" = 2 (weights 1 and 1, then repeated with weights 1 and 3), then turned multi-rater mode **off** (per F9, this should hide all rater UI and behave as a single implicit rater "Me" with weight 1) and inspected (a) what the now-single score cell displays/edits and (b) what the Results breakdown table actually used to compute the total.

**What happened:**
- After disabling multi-rater, the score-cell input in the (now supposedly single-rater) matrix silently displays **Rater 2's raw score (2)**, not Me's score (10), with absolutely no UI indication that this isn't "Me"'s value — the Raters panel and "Scoring as" selector are correctly hidden per F9, so there is no way for the user to know a second rater's data is being shown or that "Me"'s actual score (10) still exists and is untouched.
- Editing that cell while multi-rater is off (typing "6") silently overwrites **Rater 2's** score, not Me's — verified via the raw store: `{"r_me":10,"r_...":6}` after the edit — even though the UI presents this as the one and only score for that cell.
- The Results breakdown table's "Score" column for that cell independently confirmed this is not cosmetic: it showed **6.00** = `(10 + 2) / 2`, the actual weighted blend of "Me" (10) and the hidden "Rater 2" (2), *while the matrix cell the user can see and edit showed only "2"*. The number driving the recommendation and the number in the input box the user is looking at do not match, and there is no way to discover why from the UI.

**Reproduction:** `/tmp/.../scratchpad/pw/test9_multirater_bug.js` and `test9b_verify_blend_hidden.js`. Steps:
1. New decision → enable "Multi-rater mode" → Add rater.
2. Scoring as "Me", score cell = 10. Scoring as "Rater 2", score same cell = 2.
3. Turn multi-rater mode off.
4. Observe the cell now shows "2", not "10" and not any indication of ambiguity.
5. Check the Results breakdown table's Score column for that criterion: shows 6.00 (the hidden blend), not 2.00 or 10.00.

**Why CRITICAL:** This is a completely ordinary workflow explicitly invited by the spec ("Multi-rater mode... OFF by default... When on... When off, no rater UI is visible anywhere" — F9), and it silently corrupts the core output of the entire application — the ranked recommendation — with no way for the user to detect it, because the very UI that would reveal the second rater is the UI that's supposed to be hidden. A9/F6's "transparency" guarantee (every number traceable and visible) is broken in exactly the case where it matters most: the number shown and the number used disagree.

**Root cause (code review):** `DecisionEngine.cellValue()` iterates over `decision.raters` unconditionally — it has no branch on `decision.multiRater` — while `App.scoringAsRaterId` is never reset to `'r_me'` when the toggle is switched off, and `d.raters` is never collapsed/merged back to a single entry. The engine is faithful to the documented "no branching in the math layer" design, but the UI layer never enforces the single-rater invariant the plan promises ("single implicit rater... weight 1") once a second rater has ever been created in the session.

---

## HIGH

*(none beyond the two CRITICALs above — see LOW for smaller issues)*

---

## MEDIUM

### M1. Tied "Rank 1" options both get the "Recommended" badge with no distinguishing UI
When two options are exactly tied at rank 1 (verified: identical totals → both display "Recommended" + "Rank T1"), the UI presents two simultaneous "Recommended" picks. This is arguably defensible per the tie-handling spec (A13: "exactly equal totals display as a tie"), but F5 says "top result highlighted as Recommended" (singular), and having two cards both badged "Recommended" could read as a UI mistake rather than a deliberate tie signal to an end user unfamiliar with the tie convention. Flagging for product judgment rather than as a clear-cut break; not blocking.

---

## LOW

### L1. Decimal / malformed score-cell input is truncated via `parseInt`, not rejected or rounded
Programmatically driving the score-cell `input` event with `"3.7"` results in a stored score of `3` (`parseInt` truncation) rather than rejecting the value or rounding to nearest integer (4). Low impact because the native `<input type="number" step="1">` control makes it hard for a real user to end up with a fractional string in practice (arrow keys/spinner respect `step`), but the value could arrive via paste or programmatic autofill and the resulting silent truncation is a bit surprising (3.7 "rounds down" instead of rounding to nearest). Also note: a raw value of `"0"` (below the documented 1–10 scale) is silently clamped to `1` rather than rejected — consistent with the app's general clamp-not-reject philosophy elsewhere, so I'm not flagging that half separately, just noting it for awareness.

### L2. Tab order includes two dead controls at the very start of every session (consequence of C1)
**[ROUND 2: FIXED — confirmed the 2nd Tab stop after the skip-link is now `#decision-title-input`.]**

Documented under C1's downstream effects; listed separately here only because it's independently an N5 (keyboard navigability) concern: a screen-reader or keyboard user starting a fresh session tabs into "Dismiss" (for a corruption banner that doesn't exist) and "Export session JSON" (for a quota error that hasn't happened) before reaching the app's real controls. Will resolve automatically once C1 is fixed.

---

## What I verified working correctly (i.e., could not break) — round 1

- **A1/A2** — Fresh load: zero console messages, zero network requests beyond the initial `file://` document load, no external `src=`/`href=`/`@import`/`fetch`/`XHR` references found in the file.
- **A3** — New decisions always seed "Do Nothing (status quo)" flagged `isStatusQuo: true`.
- **A4** — Normalized percentages update live and sum to exactly 100.0% under repeated weight changes (verified 5/5/8 → 27.8/27.8/44.4 = 100.0).
- **A5** — Hand-computed totals for a 3-criteria/3-option matrix matched the live UI exactly (7.11, 5.56, 5.28), and each option's displayed contribution breakdown summed exactly to its displayed total.
- **A6** — Flipping a criterion's direction fully inverted the ranking of two options that were previously opposite extremes on that criterion (totals 7.5/3.0 became 3.0/7.5).
- **A7** — An unscored cell showed Score = 5.50 in the breakdown, an "N of M criteria unscored" badge on the option, and the option still ranked.
- **A8** — Title, renamed criterion, and a scored cell all survived a full page reload intact.
- **A9** — Export gating precisely matched spec: blocked with an exact missing-items list when `hard_to_reverse` and any of (assumption / trigger / top option's premortem) are empty; each checklist link correctly moved focus to the right field; enabled immediately once all three are filled; always enabled when `Reversible`, even with everything else blank. Attempting to force-click a disabled export button produced no download.
- **A10** — Print/Markdown output verified to contain the recommendation, every alternative with total/premortem, criteria with weight/normalized %, load-bearing assumption, and revisit trigger.
- **A11** — Exported session JSON imported into a completely fresh browser profile: appended as a new decision with a new id, titled "... (imported)", original (default) decision in that profile left untouched.
- **A12** — Two raters with weights 1 and 3 scoring 10 and 2 on the same cell blended to exactly 4.0 = (1×10+3×2)/4 in the "Scoring as" blended readout. (Disabling the mode afterward is where C2 lives — the *math* is right, the *UI state transition* is not.)
- **A13** — Exact ties correctly rank both as `T1` with the status-quo option listed first; close-call banner fires precisely at the <5% boundary (4% margin → banner shown; exactly 5% and 10% margins → not shown), matching the self-test harness's own boundary assertions.
- **A15** — Extensive typing tests (character-by-character with pauses that straddle the 300ms save debounce, fast uninterrupted typing, mid-string caret insertion, textarea, and score-cell inputs) never lost focus, reordered the caret, or dropped a character.
- **A16** — At 380px width: no horizontal scroll (`scrollWidth === clientWidth`), no element overflowing the viewport, and the score matrix correctly reflows into per-option cards with labeled fields.
- **A17** — Completed the full flow (add criterion → adjust weight via arrow keys → add option → score every cell → export Markdown) using only keyboard focus + Enter/arrow keys, with a visible 3px focus outline at every stop (`:focus-visible` rule applies consistently).
- **A18** — Corrupting `decisionEngine.v1` to invalid JSON and reloading correctly: started a fresh session, backed up the exact original string under a new `decisionEngine.v1.corrupt.<timestamp>` key (byte-for-byte match verified), and populated the corrupt banner's text with the real explanation (the banner's *visibility* is separately broken by C1, but the underlying logic is correct). Note: a naive `localStorage.setItem(...) + page.reload()` test is misleading here because the app's own `beforeunload` handler flushes valid in-memory data over any injected corruption before the reload completes — this is expected self-healing behavior, not a bug, and I adjusted the test to block that write path to observe the true corrupted-load behavior.
- **A19** — Deleting a scored criterion pruned its entries from the live store; a genuine downloaded JSON export (not just an in-memory check) contained zero orphaned criterion/option keys in `scores`.
- **A20** — `@media print` correctly hides all chrome/buttons/nav and shows only `#markdown-preview`, confirmed via Chromium's print-media emulation and a full-page screenshot of the print layout.
- Zero-criteria / zero-option state: deleting every criterion and every option produced the correct empty-state text with no thrown JS errors, and re-adding recovered cleanly.
- XSS: injecting `<img src=x onerror=alert(1)>` into a criterion name was correctly escaped in the rendered DOM and never executed.
- 12-item caps: "Add" buttons correctly disable at 12 criteria/options, and forcing a click past the cap via `element.click()` in the console has no effect (JS-level guard, not just a disabled attribute).

---

## Summary (round 1, superseded by "ROUND 2 STATUS" / "ROUND 3 STATUS" tables above)

| Severity | Count | Items |
|---|---|---|
| CRITICAL | 2 | C1 (hidden/display CSS bug, 7 elements), C2 (multi-rater-off silently keeps blending hidden rater data) |
| HIGH | 0 | — |
| MEDIUM | 1 | M1 (dual "Recommended" badge on ties — judgment call) |
| LOW | 2 | L1 (decimal truncation on hostile score input), L2 (dead controls in tab order, consequence of C1) |

Everything else I attempted to break — the calculation engine (A5–A7, A12–A13), persistence (A8, A18), export gating and round-trip (A9–A11), orphan pruning (A19), the 380px responsive layout (A16), the full keyboard-only flow (A17), print output (A20), and focus/caret stability while typing (A15, the item flagged as highest-risk) — held up under adversarial testing. The two CRITICAL findings should block GO until fixed: C1 because it fires on every single session with no trigger required, and C2 because it silently produces a wrong ranked recommendation — the one thing this entire application exists to get right — with no way for the user to notice.
