# BUILD_PLAN.md — Weighted Decision Engine

Status: approved (all 9 clarifying questions answered "defaults"). Ready for Coder.

---

## Objective

Build a single, self-contained `index.html` decision engine that runs by double-clicking the file — no server, no build, no dependencies — letting a person weigh criteria, score options against them (including a first-class "Do Nothing" status quo), see a transparent ranked recommendation, and export a decision record that captures the alternatives, the load-bearing assumption, and the trigger to revisit.

---

## Requirements

### Functional

- [ ] F1. Criteria: add, rename, delete. Each has a weight slider (integer 1–10) and a direction toggle (`higher is better` / `lower is better`). Normalized weight shown live as a percentage.
- [ ] F2. Options: add, rename, delete. Each has a premortem field ("if this fails, why") and a status-quo flag.
- [ ] F3. A "Do Nothing (status quo)" option is seeded into every new decision, flagged as status quo. It is deletable, but if no option is flagged status quo a persistent nudge appears above the matrix.
- [ ] F4. Score matrix: every (option × criterion) cell takes an integer 1–10 or is left unscored (N/A), distinct from a score of 0.
- [ ] F5. Ranking: weighted total per option, ranked descending, top result highlighted as "Recommended", recomputed live on every input change.
- [ ] F6. Transparency: each option's result shows per-criterion contribution (criterion, normalized weight, effective score, weighted contribution) as a visible breakdown, not just a total.
- [ ] F7. Reversibility flag per decision (`Reversible` / `Hard to reverse`) that changes app behavior, not just the record — see F12.
- [ ] F8. Decision framing fields: load-bearing assumption (text), revisit trigger (condition text + optional date).
- [ ] F9. Multi-rater mode ("voice vs vote"), OFF by default. When off, the app behaves as a single implicit rater named "Me" with weight 1 and no rater UI is visible anywhere. When on, a Raters panel (name + weight 1–10) appears and the matrix gains a "Scoring as: [rater]" selector.
- [ ] F10. Decision library in localStorage: multiple named decisions, switch / new / duplicate / rename / delete.
- [ ] F11. Persistence: work survives refresh and browser restart without any explicit save action.
- [ ] F12. Export gating: when reversibility is `Hard to reverse`, exports are blocked until (a) load-bearing assumption, (b) revisit trigger condition or date, and (c) the premortem of the currently top-ranked option are all non-empty. Blocked state shows a checklist of exactly what is missing, each item linking focus to the offending field. When `Reversible` or unset, exports are always enabled and those fields are optional.
- [ ] F13. Exports: (a) decision record as Markdown file download, (b) same record copy-to-clipboard, (c) full-session JSON download, (d) print-friendly view via Ctrl+P.
- [ ] F14. Import: full-session JSON via file picker, added to the library as a new decision (never silently overwriting existing work).
- [ ] F15. Close-call detection: when the relative margin between rank 1 and rank 2 is under 5%, show a "too close to call" banner on the results.
- [ ] F16. In-page self-test harness at `index.html?selftest=1` that exercises the pure calculation layer and renders pass/fail.

### Non-functional

- [ ] N1. Single file: `/home/user/ClaudeAgents/index.html`, all CSS and JS inline. Zero network requests, zero external assets, zero fonts/CDNs. Must work from `file://`.
- [ ] N2. No ES modules, no `fetch`, no XHR (all blocked or unreliable on `file://`). Plain script, `FileReader` for import.
- [ ] N3. Comfortably supports 2–8 criteria and 2–8 options; hard cap 12 each with a clear message at the cap.
- [ ] N4. Responsive down to 380px wide; below ~720px the matrix reflows from a table into per-option cards.
- [ ] N5. Keyboard navigable end to end; every input has an associated `<label>`; table headers use `scope`; results summary and save status use `aria-live="polite"`; visible focus outlines; no meaning conveyed by color alone.
- [ ] N6. Clean, calm, real-tool UI. System font stack. Legible at default zoom. No animation beyond ~150ms transitions.
- [ ] N7. Never lose user data: corrupt localStorage is backed up, not discarded; quota failures surface a visible warning instead of failing silently.
- [ ] N8. Target evergreen Chrome, Firefox, Safari, Edge (current versions).

---

## Architecture

### Layout decision (resolves a conflict in the answers)

Q1's default is "single self-contained `index.html`". Q8's default is "a `tests.html` self-test harness". These conflict: a separate `tests.html` cannot reach the engine inside a single-file `index.html` on `file://` (ES modules are CORS-blocked, `fetch('index.html')` is blocked, and cross-document access to a `file://` iframe is blocked by opaque-origin rules in Chrome and Firefox). Splitting out `engine.js` would fix it but breaks the single-file promise.

**Resolution:** keep the single file and move the harness inside it. `index.html?selftest=1` (also reachable from a footer link, and callable as `window.runSelfTests()` from the console) renders the test results instead of the app. This satisfies both defaults with no code duplication. Flagged in Risks; overrule if you'd rather have two files.

### Internal structure (one file, four layers, in this order)

1. **`DecisionEngine`** — pure functions. No DOM, no storage, no globals mutated. All ranking math lives here and only here. This is the layer the self-tests target, and the reason it must stay DOM-free.
2. **`Store`** — localStorage read/write, debounced save, migration, corruption recovery, import/export serialization.
3. **`UI`** — render functions per section plus event delegation on a small number of container listeners.
4. **`SelfTest`** — assertions against `DecisionEngine` only.

Trade-off: a single mutable state object re-rendered on change (not a virtual DOM, not fine-grained bindings). At the target scale (≤12 × 12 = 144 cells) a targeted re-render is fast enough and dramatically simpler than any reactive layer. Constraint the Coder must honor: **do not full-re-render the section containing the focused element** while typing — re-render the results panel and the derived readouts (normalized %, totals, ranks) but leave the live input's DOM node in place, or focus and caret position will be destroyed on every keystroke.

### Data model

```
Library {
  schemaVersion: 1,
  activeDecisionId: string | null,
  decisions: Decision[]
}

Decision {
  id: string,                    // "d_" + timestamp + random
  title: string,
  createdAt: ISOString,
  updatedAt: ISOString,
  reversibility: "reversible" | "hard_to_reverse" | null,   // null = not stated
  loadBearingAssumption: string,
  revisitTrigger: { condition: string, date: string | null }, // date as "YYYY-MM-DD"
  multiRater: boolean,
  raters: Rater[],               // always length >= 1
  criteria: Criterion[],
  options: Option[],
  scores: { [optionId]: { [criterionId]: { [raterId]: number | null } } }
}

Criterion { id, name: string, weight: 1..10, direction: "higher" | "lower" }
Option    { id, name: string, isStatusQuo: boolean, premortem: string }
Rater     { id, name: string, weight: 1..10 }
```

Notes:
- `raters` always contains at least the implicit rater `{ id: "r_me", name: "Me", weight: 1 }`. Single-rater mode is multi-rater mode with one rater — no branching in the math layer, only in the UI layer. This is why F9 costs almost nothing in the engine.
- `scores` is sparse. A missing key, or an explicit `null`, means unscored. Never store `0`.
- Deleting a criterion, option, or rater must prune the corresponding `scores` entries so orphans don't accumulate in exports.

### Calculation spec (must be implemented exactly as written)

Constants: `SCALE_MIN = 1`, `SCALE_MAX = 10`, `MIDPOINT = 5.5`.

1. **Direction adjustment.** For a raw score `s` on a criterion with `direction === "lower"`, the effective score is `11 - s` (so 1 → 10, 10 → 1). For `"higher"`, effective score is `s`. `MIDPOINT` is invariant under this transform, which is why 5.5 is the right neutral value.
2. **Cell value** for (option `o`, criterion `c`): let `R` = raters with a non-null score for that cell.
   - If `R` is empty → `value = MIDPOINT`, `scored = false`.
   - Else `value = Σ_{r∈R} (rater.weight × effective(s_r)) / Σ_{r∈R} rater.weight`, `scored = true`.
   - Rationale: a rater who abstains is excluded from that cell's average rather than pulled to the midpoint; only a fully unscored cell falls back to the midpoint.
3. **Normalized criterion weight.** `normalized_c = weight_c / Σ weights`. Weights are integers ≥ 1, so the denominator is never 0. Displayed percentages are rounded to one decimal and adjusted by largest-remainder so the visible column sums to exactly 100.0%.
4. **Option total.** `total_o = Σ_c (normalized_c × cellValue(o, c))`. Range is 1–10. Also report `percent = ((total − 1) / 9) × 100` for display.
5. **Contribution** of criterion `c` to option `o` = `normalized_c × cellValue(o, c)`. Contributions sum exactly to the total — the self-tests must assert this.
6. **Ranking.** Sort by `total` descending. Totals within `1e-9` are treated as tied and share a rank, displayed as `T1`, `T2`, etc. Display order among tied options: status-quo option first, then original creation order. Rationale: on a genuine tie, do nothing.
7. **Close call.** `margin = (total_1 − total_2) / total_1`. If two or more options exist and `margin < 0.05`, set `closeCall = true`.
8. **Incomplete.** Count of cells where `scored === false` per option. Incomplete options are still ranked (per Q3 default) but carry a visible "N of M criteria unscored" badge, and the results panel warns when any option is incomplete.
9. **Insufficient data.** With fewer than 2 criteria or fewer than 2 options, produce no ranking; the results panel shows guidance instead.

### Engine interface (signatures only — the Coder implements the bodies)

```js
window.DecisionEngine = {
  normalizeWeights(criteria),
  // -> [{ id, weight, normalized, percentDisplay }]  percentDisplay sums to 100.0

  cellValue(decision, optionId, criterionId),
  // -> { value: number, scored: boolean }

  scoreOption(decision, optionId),
  // -> { optionId, total, percent, contributions: [{ criterionId, normalized, value, contribution }],
  //      unscoredCount, criteriaCount }

  rankOptions(decision),
  // -> { ranked: [{ ...scoreOption, rank, tied }], closeCall, margin, sufficient }

  validateForExport(decision),
  // -> { ok, missing: [{ field, label, elementId }] }

  toMarkdown(decision),      // -> string, the decision record
  toSessionJSON(decision),   // -> string
  fromSessionJSON(text),     // -> { ok, decision?, errors? }  never throws
  migrate(rawLibrary)        // -> Library  never throws
};
```

### Persistence design

- Key: `decisionEngine.v1`. Whole `Library` serialized as one JSON blob.
- Save is debounced 300ms after the last change, and forced on `visibilitychange` (hidden) and `beforeunload`.
- Save status indicator in the header: `Saved` / `Saving…` / `Not saved — see warning`, `aria-live="polite"`.
- On load: `JSON.parse` in a try/catch. On failure, copy the raw string to `decisionEngine.v1.corrupt.<timestamp>`, start a fresh library, and show a dismissible banner explaining that the previous data was unreadable and has been kept under that key. **Never discard the raw string.**
- On `QuotaExceededError`: show a persistent banner "Changes are no longer being saved — export your decision now" with an Export button in it.
- `migrate()` switches on `schemaVersion` with a default branch that treats unknown/absent versions as v1 and repairs missing fields with defaults.

### Export design

- **Markdown record** (`toMarkdown`) sections, in order: Decision title and date; Reversibility (with the one-line consequence); Recommendation (top option + total + margin + close-call warning if set); Alternatives considered (every option with total, rank, status-quo marker, premortem); Criteria and weights (name, weight, normalized %, direction); Full score matrix (options × criteria, with `—` for unscored); Load-bearing assumption; Revisit trigger (condition + date); Raters and their weights (only if `multiRater`); footer line with generation timestamp.
- **Download** via `Blob` + `URL.createObjectURL` + `<a download>` + `revokeObjectURL`. Filenames: `<slugified-title>-decision-record.md` and `<slugified-title>-session.json`.
- **Copy to clipboard** — three-tier fallback, all inside the click handler: `navigator.clipboard.writeText` → `document.execCommand('copy')` on a temporary textarea → reveal a pre-selected textarea with "press Ctrl+C". `file://` clipboard behavior is inconsistent across browsers, so all three tiers are required, not optional.
- **Import** via `<input type="file" accept=".json">` + `FileReader.readAsText`. Validate shape through `fromSessionJSON`; on failure show the specific errors and change nothing. On success, assign fresh ids and append to the library as `"<title> (imported)"`.
- **Print**: `@media print` hides all controls, chrome, and the library switcher, and prints the decision record view only.

### UI structure (single page, stepped sections, all visible — no wizard)

- **Header** — app name, decision title input, library `<select>` + New / Duplicate / Delete, save status.
- **1. Frame the decision** — reversibility radio pair with consequence text (`Reversible: decide fast, keep it cheap and move.` / `Hard to reverse: assumption, trigger, and a premortem are required before you can export.`), load-bearing assumption textarea, revisit trigger condition + date.
- **2. Criteria** — rows of: name, weight slider 1–10 with numeric readout, live normalized %, direction toggle, delete. "Add criterion" button.
- **3. Options** — cards of: name, "This is the status quo / do nothing" toggle (only one option may hold it at a time), premortem textarea, delete. "Add option" button. Status-quo nudge if none flagged.
- **4. Score** — matrix table, rows = options, columns = criteria, cells = 1–10 input with a clear-to-N/A affordance. Column headers show the criterion name, its normalized %, and a direction indicator. Multi-rater toggle sits above; when on, reveals the Raters panel and a "Scoring as: [rater ▾]" selector, with the cell showing the current rater's value and the blended value in smaller text beneath. **The matrix stays 2D in all modes** — this is the whole reason multi-rater doesn't overcomplicate the core flow.
- **5. Result** — ranked cards; rank 1 marked "Recommended" by badge text and position, not color alone; total, percent, and a horizontal stacked bar of per-criterion contributions with a labeled breakdown table underneath; close-call banner; incomplete badges.
- **6. Decision record** — live Markdown preview, gating checklist when blocked, and the four export actions.

---

## Task breakdown

Execute in order. Each task should leave the file openable and working.

1. **Scaffold** `/home/user/ClaudeAgents/index.html`: doctype, meta viewport, inline `<style>`, inline `<script>`, section skeletons for the six sections, header. No logic yet. Verify it opens from `file://` with zero console errors and zero network requests.
2. **Styles**: system font stack, layout grid, card/table/form styling, focus-visible outlines, responsive breakpoint at 720px, `@media print` block. Static markup only at this stage.
3. **State + defaults**: `Library` / `Decision` factories, id generator, the seeded new-decision content (2 starter criteria, the "Do Nothing (status quo)" option, implicit rater `r_me`).
4. **`DecisionEngine` pure layer**: implement every function in the interface above exactly to the calculation spec. No DOM access in this layer.
5. **`SelfTest` harness**: `?selftest=1` routing, assertion helpers, and the test list in Acceptance Criteria A14. Renders a summary line with the exact text `SELFTEST PASS: <n> FAIL: <m>` in an element with id `selftest-summary`, plus per-test rows. Run it — all must pass before continuing.
6. **`Store`**: load, debounced save, save-status indicator, corruption backup, quota banner, `migrate()`.
7. **Criteria UI**: render, add, rename, delete, weight slider with live normalized %, direction toggle. Wire to store.
8. **Options UI**: render, add, rename, delete, premortem, status-quo toggle with single-selection enforcement and the no-status-quo nudge.
9. **Score matrix UI**: render table from state, cell input with 1–10 validation and clear-to-N/A, score pruning on criterion/option delete, responsive card fallback under 720px. Confirm typing in a cell never loses focus or caret.
10. **Results UI**: ranked cards, recommended badge, contribution bars and breakdown table, tie display, close-call banner, incomplete badges, insufficient-data empty state, `aria-live` on the summary.
11. **Framing UI + gating**: reversibility radios with consequence text, assumption, trigger; `validateForExport` wired to disable exports and render the missing-items checklist with focus links.
12. **Exports**: `toMarkdown` preview, Markdown download, JSON download, clipboard with all three fallback tiers, print stylesheet verification.
13. **Import**: file input, `fromSessionJSON` validation, error surfacing, append-as-new-decision.
14. **Library management**: switcher, new, duplicate, rename, delete with confirmation, `activeDecisionId` persistence.
15. **Caps and polish**: 12-criteria / 12-option caps with messaging, empty states for every section, keyboard pass end to end, labels and `scope` attributes audit, 380px width check.
16. **`README.md` update**: a short "Open `index.html` in a browser" section describing what the app does and where the self-tests live.

---

## Acceptance criteria

These are the Tester's target. Each must be verifiable by opening the file directly from disk.

- **A1.** Opening `file:///home/user/ClaudeAgents/index.html` renders the full app with no console errors and no network requests (verify the Network tab is empty).
- **A2.** No external references exist in the file: no `src=`/`href=` pointing off-file except anchors, no CDN URLs, no `@import`, no `fetch`/`XMLHttpRequest`/`import(`.
- **A3.** A new session starts with a status-quo "Do Nothing" option present and flagged.
- **A4.** Adding criteria and changing any weight updates the normalized percentages live, and the displayed percentages sum to exactly 100.0%.
- **A5.** With 3 criteria and 3 options fully scored, the totals computed by hand from the spec match the app's totals to 2 decimal places, and each option's listed contributions sum to its displayed total.
- **A6.** Flipping a criterion to "lower is better" reverses that criterion's contribution ordering across options (an option scoring 10 becomes the weakest on that criterion).
- **A7.** Leaving a cell unscored yields exactly the midpoint 5.5 contribution basis for that cell, shows an "unscored" badge on the option, and still ranks the option.
- **A8.** Editing anything, then refreshing the browser, restores the exact prior state including active decision, scores, and text fields.
- **A9.** Setting reversibility to "Hard to reverse" with any of (assumption, trigger, top option's premortem) empty disables all export actions and lists exactly the missing items; filling all three enables exports. Setting "Reversible" enables exports regardless.
- **A10.** Markdown export contains, at minimum: the recommendation, every option with its score and premortem, all criteria with weights and normalized percentages, the load-bearing assumption, and the revisit trigger.
- **A11.** Exported session JSON re-imported into a fresh browser profile (cleared localStorage) reproduces an identical decision, with a new id, without disturbing existing decisions.
- **A12.** Enabling multi-rater mode with 2 raters of unequal weight produces cell values equal to the weight-weighted mean of the raters' scores; disabling the mode returns the app to the single-rater view without data loss.
- **A13.** Two options whose totals differ by under 5% trigger the close-call banner; exactly equal totals display as a tie with the status-quo option listed first.
- **A14.** `index.html?selftest=1` reports `SELFTEST PASS: n FAIL: 0`, with tests covering at minimum: weight normalization including the rounding fix-up; direction inversion; unscored-cell midpoint; per-rater weighted aggregation; contributions summing to total; rank ordering and tie handling; close-call threshold at the boundary; `validateForExport` for both reversibility states; `fromSessionJSON` rejecting malformed input without throwing; `migrate()` on an empty/garbage object without throwing.
- **A15.** Typing continuously in a criterion name, a premortem, or a score cell never loses focus, never reorders the caret, and never drops characters.
- **A16.** At 380px width the matrix is usable (card fallback), no horizontal page scroll, and all controls remain reachable.
- **A17.** The entire flow — add criterion, set weight, add option, score every cell, export — is completable using only the keyboard, with a visible focus indicator at every step.
- **A18.** Corrupting the `decisionEngine.v1` localStorage value to invalid JSON, then reloading, produces a fresh session plus a visible warning, and the original string is still retrievable from a `decisionEngine.v1.corrupt.*` key.
- **A19.** Deleting a criterion or option removes its score entries; a subsequent JSON export contains no orphaned score keys.
- **A20.** Ctrl+P produces a clean printed decision record with no buttons, sliders, or navigation chrome.

---

## Risks and open questions

1. **Single-file vs. separate test file (resolved, flag for review).** The self-test harness lives inside `index.html` behind `?selftest=1` because a separate `tests.html` cannot access a single-file app's internals on `file://`. If the reviewer prefers a literal `tests.html`, the engine must be extracted into `engine.js` and the single-file property is lost. Decision made in favor of single file; reversible in one task.
2. **Clipboard on `file://`.** Behavior differs across browsers and may require a user gesture or fail outright. Mitigated by the mandatory three-tier fallback, but the Tester should check all three paths and treat a failure of tier 1 alone as non-blocking.
3. **Blob downloads on `file://`.** Reliable in Chrome/Firefox/Edge; Safari has historically been quirky with the `download` attribute on `file://` pages. If downloads fail in Safari, the clipboard path and print path are the fallbacks. Not a blocker for GO.
4. **Unscored cells default to the midpoint.** This is the answered default, but it is a real modeling choice: it flatters incomplete options relative to genuinely weak ones. Mitigated with visible badges and a results-panel warning. Revisit if it misleads in practice.
5. **Re-render vs. focus.** The most likely functional bug in this build is caret/focus loss from over-eager re-rendering. Called out as an explicit constraint (Architecture) and an acceptance criterion (A15).
6. **Multi-rater surface area.** Even in the "scoring as" design, it roughly doubles the matrix's state paths. If it threatens the core flow's quality during implementation, ship it hidden behind the toggle exactly as specified and do not expand it further.
7. **Open question (non-blocking, deferred to v2).** No sensitivity analysis: the app flags a close call but does not tell the user which weight change would flip the result. Explicitly out of scope per the Q9 default.
8. **Open question (non-blocking).** Nothing in the plan versions or timestamps a *decided* decision — the revisit trigger is recorded but never surfaces again. A future "decisions due for review" view would close that loop; out of scope for v1.

---

## Extension: Levers, Reasoning, and Charts (v1.1)

Source: the user supplied the novel *Load-Bearing* (the book the framework in this project's context was excerpted from) and asked for two gaps to be closed, plus the tool made more visual, matching what the book's Chapter 5 ("What the Business Is Actually Buying") and Chapter 7 ("Deciding Without a Right Answer") describe and what the Atlas appendix depicts as hand-drawn diagrams. Scope call made by the orchestrator: the book's Ceiling (depth/leverage) and Ledger (output/outcome) sketches are about personal career leverage, not about evaluating options between alternatives, so they don't fit this tool and are excluded. The **Strategy Alignment Map** (initiatives traced to the levers leadership is actually measured on) and the scoring visualizations are what's in scope, since both map directly onto what this tool already does: score options against criteria.

### New requirements

- [ ] E1. **Levers list.** A decision gains an optional, small named list of levers (e.g. "Cost certainty," "Visible win before the vote"), managed like the existing Raters list (add/rename/delete), capped at 8. Matches the book's "leadership is measured on five or six levers."
- [ ] E2. **Criterion → lever mapping.** Each criterion gets an optional single-select "Serves lever" dropdown (one of the decision's levers, or "No lever"). A criterion with no lever assigned is an **orphan** per the book's usage ("orphans connect to no lever, kill or connect, no third option"). This is a single-select simplification of the book's many-to-many map — deliberate, to keep the UI a dropdown per criterion rather than an NxM checkbox grid.
- [ ] E3. **Lever Alignment Map** — a new subsection under Criteria (or its own step) rendering an inline-SVG bipartite diagram: levers in one column, criteria in the other, a line connecting each criterion to its lever. Orphan criteria (no lever) are visually flagged (e.g. a dashed stub with a warning color, no line to any lever). Levers with zero incoming criteria are visually flagged as **unserved** (per the book: "a lever no initiative serves is an opportunity, not a gap") — different visual treatment from an orphan criterion, since the two are opposite problems. Updates live as criteria/levers/mappings change. If there are zero levers defined, show an empty state explaining what the map is for rather than an empty diagram.
- [ ] E4. **Reasoning field.** Add a `reasoning` free-text field to the decision (alongside the existing load-bearing assumption and revisit trigger, in "1. Frame the decision"), matching the book's four-part decision record (decided / alternatives / assumptions / **reasoning**) — the connective narrative from assumptions to the choice, distinct from the assumption itself. Include it in export gating: when reversibility is "Hard to reverse," `reasoning` becomes a required field alongside the existing three (assumption, trigger, top option's premortem). Include it in the Markdown decision record, positioned after "Recommendation" and before "Load-bearing assumption."
- [ ] E5. **Ranked results bar chart.** Replace or augment the current ranked list in "5. Result" with an inline-SVG horizontal bar chart, one bar per option, length proportional to weighted total (0–10 scale), labeled with the option name and total, recommended option visually distinguished (not by color alone — also a badge/marker, consistent with N5's existing color-blindness rule). Show the close-call margin visually when it applies (e.g. a bracket or tick between the top two bars), not just as the existing text banner.
- [ ] E6. **Criteria comparison radar/spider chart.** A new inline-SVG radar chart in "5. Result," one axis per criterion (using each option's effective per-criterion score, 1–10 scale, already computed by `cellValue`), one polygon per option, overlaid, with a legend mapping polygon style (not color alone) to option name. This is the tool's answer to "which option wins on which dimension," genuinely new insight beyond the existing text breakdown table. Only render when there are at least 3 criteria (a radar chart with 1–2 axes is degenerate); show a short note instead below that threshold.
- [ ] E7. Both new charts and the alignment map must update live on every relevant input change, matching the rest of the app's live-recompute behavior, and must not cause the focus/caret-loss regression class from A15 — they render in the read-only Results/Criteria areas, which are not text-input-focusable, so this should be low-risk, but must be verified.

### Non-functional additions

- [ ] E8. All new charts/diagrams are inline SVG, hand-built with plain JS (no chart library, no CDN, no network — consistent with N1/N2). Must render correctly in the existing dark/light-agnostic, `file://`, no-network constraints.
- [ ] E9. Charts must be keyboard/screen-reader accessible per N5: an `aria-label` or adjacent visually-hidden text summarizing what the chart shows in words (e.g. "Bar chart: Option B leads at 8.0 of 10, Option A at 2.0 of 10"), since SVG shapes alone aren't screen-reader-legible. Data must also remain available in the existing text form (the breakdown table, the ranked list) — charts are additive, not a replacement for the accessible text representation.
- [ ] E10. Must not regress any of the existing 41 self-test assertions or A1–A20 acceptance criteria. New pure logic (lever-orphan detection, unserved-lever detection, chart coordinate/scaling math) should get self-test coverage of its own where it's non-trivial (e.g. an orphan/unserved-lever detector, and the radar-chart point-generation math for a known input).
- [ ] E11. `toSessionJSON`/`fromSessionJSON`/`migrate`/`repairDecision` must be extended to cover `levers` and each criterion's `leverId`, and `reasoning`, with the same repair/backward-compatibility discipline as every other field (a decision saved before this extension, with no `levers` array and no `reasoning` field, must load cleanly with `levers: []`, every criterion's `leverId: null`, and `reasoning: ''`).

### Data model additions

```
Decision gains:
  reasoning: string
  levers: Lever[]            // capped at 8, like raters

Lever { id, name: string, weight: 1..10 }   // weight: same slider pattern as Rater weight, but the model does not (yet) do "outcome, not activity" weighted scoring by lever value in v1.1 — it is a
                                              // future direction, not required here. Keep it if easy, but the alignment map itself (E3) does not depend on lever weight, only lever identity.
Criterion gains:
  leverId: string | null      // null = orphan (no lever assigned)
```

Note on `Lever.weight`: it is optional scope — E3's alignment map only needs lever *names*, not weights. Do not let a lever-weighting feature expand this extension's surface; if it adds complexity, cut it and keep `Lever` as just `{ id, name }`.

### Task breakdown (extends the original task list)

1. Data model: `Lever` factory/repair function, `levers` and `reasoning` on `Decision`, `leverId` on `Criterion`, all wired through `repairDecision`/`migrate`/`fromSessionJSON`/`toSessionJSON` per E11.
2. Levers UI: add/rename/delete list (reuse the Raters-panel UI pattern), capped at 8.
3. Criterion "Serves lever" dropdown, populated from the decision's levers, defaulting to "No lever."
4. Pure engine function(s) for orphan-criteria and unserved-lever detection, self-tested.
5. Lever Alignment Map SVG rendering, live-updating, with the empty state and both flagged states (orphan criterion, unserved lever).
6. Reasoning field UI in "1. Frame the decision," wired to state/store.
7. Export gating (E4) and Markdown export (E4) updated for `reasoning`.
8. Ranked results bar chart (E5), live-updating, with the accessible text summary (E9).
9. Criteria comparison radar chart (E6), live-updating, with the 3-criteria-minimum guard and accessible text summary (E9).
10. Full self-test pass plus a manual walkthrough of the new UI; confirm no regression in the existing 41 assertions.

### Acceptance criteria (extends A1–A20)

- **E-A1.** A criterion with no lever assigned renders as a visually flagged orphan in the alignment map; assigning it a lever removes the flag and draws the connecting line, live, without a page reload.
- **E-A2.** A lever with no criteria assigned to it renders as a visually flagged "unserved" lever in the alignment map, distinguishable from the orphan-criterion flag (different treatment, since they're opposite problems).
- **E-A3.** With reversibility set to "Hard to reverse," `reasoning` empty blocks export and appears in the missing-items checklist (per the existing F12 gating pattern); filling it (alongside the other three) enables export.
- **E-A4.** The Markdown export contains a "Reasoning" section, positioned after the recommendation and before the load-bearing assumption, when `reasoning` is non-empty.
- **E-A5.** The ranked results bar chart's bar lengths are proportional to each option's actual computed total (spot-checkable against the existing breakdown table's numbers) and the recommended option is distinguishable by more than color.
- **E-A6.** The radar chart's per-axis position for each option matches that option's `cellValue` for that criterion (spot-checkable), and it does not render (shows the fallback note instead) with fewer than 3 criteria.
- **E-A7.** Deleting a lever that criteria reference reassigns those criteria to "No lever" (orphan) rather than leaving a dangling `leverId`, mirroring the existing criterion/option/rater deletion-pruning discipline.
- **E-A8.** A session saved before this extension (no `levers`, no `reasoning`, criteria with no `leverId`) imports/loads cleanly with sensible defaults and no thrown errors.
- **E-A9.** All charts and the alignment map have an accessible text alternative (E9) confirmed present via the DOM (not just visually).
- **E-A10.** The full existing self-test suite (41 assertions) still reports 0 failures, and a manual pass confirms A15 (focus/caret preservation) is unaffected by the new live-updating charts.
