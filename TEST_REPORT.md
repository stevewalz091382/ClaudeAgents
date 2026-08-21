# TEST_REPORT.md — Resource Optimization Engine (ROE)

Tester pass against `index.html` and `BUILD_PLAN.md` §9. All specs are real Playwright specs under
`tests/specs/`, run headlessly against the real `file://index.html` (per the harness scaffolding
already in the repo), not read-only code review. 68 tests were written and executed; **66 passed,
2 failed** (both failures are genuine, reproducible product defects, not test flakiness — each is
isolated with a control test showing the passing counterfactual).

**Environment note (affects what could be tested):** the outbound proxy in this sandbox blocks
`cdn.jsdelivr.net` (confirmed via `curl "$HTTPS_PROXY/__agentproxy/status"`, which shows repeated
`connect_rejected` / gateway 403 entries for that host), which is the same failure the Coder
reported in their own sandbox. `npx playwright install` also could not download a Chromium build
(same CDN policy blocks `cdn.playwright.dev`); testing was only possible after pointing a local
Playwright config override at a pre-installed Chromium build found at
`/opt/pw-browsers/chromium-1194/chrome-linux/chrome`. **Practical effect: Chart.js and SheetJS
never load in this environment, so the real chart-rendering path and the real
export-file-download → import-file-upload cycle could not be exercised end-to-end.** Everything
that does not require those two libraries — including the pure `ROE.io` build/parse/diff functions,
the real import-merge UI flow, and the vendor-degradation banner — was fully exercised.

How to reproduce any test below: from `tests/`, `npm install`, then run Playwright pointed at a
working Chromium (see `pw.local.config.js` pattern above if the sandboxed CDN is also blocked for
you), e.g. `npx playwright test --config=<override> <spec-file>`.

---

## CRITICAL

### 1. Session-only mode does not actually cause "reload loses everything" once data was already persisted — the core promise of the toggle is broken for the realistic case

**§9 criterion violated:** Persistence → *"Session-only mode ON → reload loses everything and the badge was visible the whole time."*

**What I did:**
1. Loaded the app fresh, clicked **Load demo data** (auto-persists via the 400ms debounced save).
2. Waited for the save to complete (600ms), navigated to Data & Settings, and checked the real
   **"Session only"** checkbox (`#set-sessionOnly`) — the actual UI control, not a store API call.
3. Confirmed the session badge became visible immediately (it did).
4. Reloaded the page (`page.reload()`).

**What happened:** All 40 demo employees (and all other demo records) reappeared after reload.

**What should have happened:** Per §9, turning session-only ON and reloading should lose
everything.

**Root cause (read from `index.html`):** `ROE.store.setSessionOnly(true)` only sets an in-memory
flag that causes *future* writes to be skipped (`scheduleSave()`/`persist()` both early-return when
`state.settings.sessionOnly` is true). It never clears data already sitting in IndexedDB from
*before* the toggle was flipped, and `ROE.store.load()` unconditionally reads all object stores on
boot regardless of any in-memory flag from the previous session. Worse, the persisted `settings`
record's own `sessionOnly` field is also never updated to `true` on disk, because `scheduleSave()`
is a no-op once `sessionOnly` is true — so the write that would have recorded "the user wanted
session-only" never happens either.

I isolated this precisely with a control test that proves it's specific to *pre-existing* data:
turning session-only ON **before** any data exists, then loading demo data, then reloading, **does**
correctly lose everything (this control passes). The moment there is data on disk *before* the
toggle is flipped — which is the normal, realistic sequence of events for almost any user (add
some data, then later decide to go session-only) — the guarantee silently fails.

**Reproduce:** `tests/specs/persistence.spec.js` → `"BUG: toggling session-only ON, via the real
settings checkbox, *after* data was already persisted does NOT lose it on reload"` (fails; expected
0 employees after reload, got 40). Control showing the narrower case that *does* work:
`"CONTROL: session-only turned on BEFORE any data ever existed..."` (passes).

**Impact:** This is a data-privacy/trust feature — a user who flips this toggle believes (and is
told, via the badge) that "nothing is being saved," but their previously-saved data is not
actually purged and will resurface on the next reload/session, on the same machine, contradicting
the UI's own claim.

---

### 2. The API connector has no UI path to ever enable any entity, configure per-entity paths, or map fields — it is non-functional for any real user out of the box

**§9 criteria affected:** essentially the entire "API" acceptance block, plus F-12 and the §7
panel spec ("API connector config + pull/push" with "field-mapping UI" and "per-entity path").

**What I did:** Loaded the app, went to Data & Settings, set a base URL, and clicked
**"Pull employees (preview)"** with completely default settings (i.e., what any real, first-time
user would see).

**What happened:** The pull silently fails with a toast: `"Pull failed: Entity 'employees' is not
enabled."` I then inspected the entire rendered Data & Settings panel HTML and confirmed:
- There is **no checkbox or control anywhere** to set `settings.api.entities.<name>.enabled`
  (every entity defaults to `enabled:false` in `ROE.const.DEFAULT_SETTINGS`, and nothing in
  `ROE.ui` ever writes to it).
- There is **no field-mapping UI** at all, despite F-12 explicitly requiring one
  ("field-mapping UI" appears twice in the plan for this feature).
- There are **no per-entity path inputs** (`pullPath`/`pushPath`/`responseRoot`) exposed anywhere.
- Only **one** pull button and **one** push button exist, both hardcoded to the `"employees"`
  entity — `projects`, `demands`, `assignments`, and `skills` have zero UI wiring at all, even
  though the data model (`Settings.api.entities`) explicitly lists all five.

**What should have happened:** Per F-12 and §7, the Data & Settings panel should let a user enable
entities, set per-entity paths, and map fields through the UI, for all five entity types.

**Reproduce:** `tests/specs/api-connector.spec.js` → `"CRITICAL: there is no UI control anywhere to
enable an entity for pull/push..."` and `"only the 'employees' entity has any pull/push wiring at
all..."` (both pass, i.e. both confirm the gap exists as described).

**Important nuance:** the underlying pure/impure functions (`ROE.api.pull/push/diffPull/diffPush`,
CORS-vs-HTTP error classification, field mapping via dot-paths) all work correctly — I verified this
by force-enabling the entity directly via `ROE.store.setSettings(...)` (bypassing the missing UI)
and running the full pull → diff preview → apply, and push → preview → send flows against a mocked
endpoint; all of that machinery is correct (see the "Verified working" section below). **The defect
is entirely in the missing UI surface**, which makes the whole connector unreachable for a real user
who cannot open devtools and call internal `ROE.*` functions by hand. Given F-12 frames this as an
optional-but-shipped feature with its own panel section and multiple named §9 acceptance bullets,
and none of those bullets can currently be exercised by an actual user, I'm ranking this CRITICAL
rather than a documentation/polish gap.

---

## HIGH

### 3. A saved optimizer weight preset does not restore the exact original slider weights after reload — they are silently renormalized

**§9 criterion violated:** Optimizer → *"a saved preset restores the exact weights after reload."*

**What I did:** In the real Optimizer panel, set all four weight sliders to `10` (skill,
availability, seniority, discipline — a legal state per §4.4, since "sliders are 0-100 ints,
normalized at read time," and nothing requires them to sum to 100 before saving). Saved this as a
preset named "ExactWeightsPreset" via the real **Save preset** button and the native prompt.
Reloaded the page, navigated back to Optimizer, and selected the preset from the dropdown.

**What happened:** All four sliders came back as `25`, not `10`.

**What should have happened:** The sliders should read back exactly `10/10/10/10`.

**Root cause:** `STORE.setWeightPreset()` stores `SCORE.normalizeWeights(os.weights)` — i.e. the
*normalized fractions* (`0.25/0.25/0.25/0.25`, since `10+10+10+10=40` and each divided by 40 is
0.25) — not the raw slider ints. The preset-select handler then does the reverse conversion
(`Math.round(p.weights.skill*100)`, etc.), which reconstructs `25` from `0.25`, not the original
`10`. Any raw weight combination that doesn't already sum to exactly 100 loses its original values
permanently once saved as a preset; only the *relative proportions* are preserved, not the exact
input the acceptance criterion calls for.

**Reproduce:** `tests/specs/optimizer-ui.spec.js` → `"BUG: a saved preset does NOT restore the
exact raw slider weights after reload..."`.

**Impact:** Medium-to-high functional impact (the optimizer still works and reorders correctly —
the *ranking* is unaffected since normalization happens at read time either way — but the specific,
named acceptance guarantee about preset fidelity is false for the common case of sliders not
summing to 100, which is the default/expected user behavior since nothing in the UI nudges users
toward round numbers).

---

## MEDIUM

None found at Medium severity that isn't already captured above or downgraded to Low below — see
notes on Finding 2's "single entity wired" sub-issue, which is folded into the Critical finding
since it's part of the same root defect.

---

## LOW

### 4. `ROE.store.subscribe()`/`notify()` has no subscribers anywhere in `ROE.ui` — the store's own pub/sub is dead code

BUILD_PLAN.md §2.2 explicitly lists "subscribe/notify" as part of `ROE.store`'s architecture. In
practice, `grep`-ing the file for `STORE.subscribe(` finds zero call sites; every render is driven
by hand-wired calls (`renderAll()`, `renderOptimizerResults()`, etc.) placed directly inside each
event handler. This currently works because every code path that mutates state today happens to
also call one of those render functions immediately afterward. But it means the badge (or any
other UI) will *not* update if a store mutation happens through any path that isn't one of those
specific hand-wired handlers — I demonstrated this concretely: calling
`ROE.store.setSessionOnly(true)` directly (e.g. from a console, or from a future code path) leaves
the session badge showing "not visible" even though the flag is now true, whereas the real checkbox
handler correctly also calls `updateSessionBadge()` itself. This is an architectural smell (declared
mechanism unused, correctness resting entirely on manual discipline at every call site) rather than
a currently-observable user-facing bug. Reproduce: `tests/specs/persistence.spec.js` →
`"NOTE: STORE.subscribe()/notify() has no subscribers..."`.

### 5. CSV per-sheet export is disabled whenever the (unrelated) SheetJS/XLSX CDN fails to load

`buildCsvForSheet`/`downloadText` never touch `window.XLSX` — CSV export is pure JS. Yet the
"Export CSV (per sheet)" button is disabled by the same `v.xlsx` check used for the actual
XLSX-dependent buttons, so a CDN outage takes down a feature that has no real dependency on the
CDN. This technically satisfies the letter of the §9 Global bullet ("charts and import/export are
disabled with a visible explanation"), so it is not scored as a failure, but it's a missed
opportunity to keep a genuinely-independent feature alive during a CDN outage. Reproduce:
`tests/specs/workbook-io.spec.js` → `"NOTE: CSV per-sheet export is disabled..."`.

### 6. Discipline adjacency table is not literally what's printed in BUILD_PLAN.md §3

The plan's own printed table (§3) is not symmetric as written (e.g., it lists `Structural ↔ Civil`
under Structural's row but omits `Structural` from Civil's row). The Coder's `ROE.const.ADJACENCY`
resolves this by adding the missing reverse edges so the table is genuinely symmetric in code
(verified by hand-checking every edge). This is a reasonable, arguably-correct interpretation of an
internally-inconsistent spec, but it is a silent deviation from the literal plan text that should be
called out and confirmed with the Architect/Manager rather than left implicit.

### 7. Test-harness environment note (not a defect in `index.html`)

The scaffolded `tests/package.json`/`playwright.config.js` assume `npx playwright install` can
reach `cdn.playwright.dev` for browser binaries. In network-restricted environments (like this one,
and apparently the Coder's own sandbox for the app's CDNs) that download is blocked. A pre-installed
Chromium happened to be available on this machine at a fixed path, which is what made any of this
testing possible at all; without it, the harness as scaffolded cannot run anywhere the two CDN
hosts are blocked. Worth a documented fallback (e.g. `PLAYWRIGHT_BROWSERS_PATH` guidance or a
vendored browser) so the harness is reliable in CI environments with similar restrictions.

---

## Verified working (confirmed, not just re-read from source)

Everything below was exercised as a real, executed Playwright test (pure-function level via
`page.evaluate()` against the real `ROE.*` namespaces and/or real UI interaction against the real
`file://index.html`), and passed:

- **Formulas exactly match §4:** `ctxTax(1)=0, ctxTax(2)=7, ctxTax(5)=28, ctxTax(9)=30`;
  `effectiveCapacity(targetUtil=85, n=3) = 73.1`; `free()` never negative, `netCap()` can go
  negative; a single 0%-allocation entry does not count as a "concurrent project."
- **Optimizer:** identical ranking across 100 runs (deterministic); weighted sub-score sum +
  clamped modifiers reproduces the displayed `matchScore` (respecting the documented 0–100 clamp);
  a fully-saturated candidate scores `availability=0`; `requireMinSkillLevels=true` excludes
  below-minimum candidates with the exact reason string; weight sliders visibly reorder the
  candidate list; every candidate's breakdown is reachable in exactly one click (Review button);
  nothing is written to the store until Commit is pressed (both at the pure-solver level and via
  real UI clicks); committing adds exactly one `Committed`/`source:"optimizer"` assignment.
- **Auto-staff:** never over-allocates past `effectiveCapacity` (checked against the real ~120-
  assignment demo dataset across all 12 projects, simulating "Commit all"); a project with zero
  eligible employees yields zero proposals and an explicit, non-empty reason per unfilled opening.
- **Alerts:** demo data fires at least one alert from **all 8** rules (`SUSTAINED_OVERALLOC`,
  `OVER_TARGET`, `CTX_OVERLOAD`, `BURNOUT_COMPOSITE`, `BENCH_RISK`, `UNSTAFFED_DEMAND`,
  `TEAM_SIZE`, `SKILL_GAP`); burnout composite score matches a hand-computed fixture to full
  floating-point precision; raising `overallocPct` 100→130 reduces the `SUSTAINED_OVERALLOC` count;
  alerts are correctly derived-not-persisted (rebuilding an equivalent state reproduces an
  identical alert set).
- **Mentorship:** a mentor at 2 active mentees never appears in suggestions; suggestions are
  ordered by `pairScore` desc with none below 35; `compatFor` boundaries are exact at 75 and 50.
- **Persistence (non-session-only path):** data survives reload; "Clear all data" requires typing
  `CLEAR` (wrong text is a no-op, verified via the real native `prompt()` dialog) and empties every
  IndexedDB object store (both the topbar and Data & Settings buttons); a session-only toggle
  flipped **before** any data exists correctly loses everything on reload (the narrower, working
  case — see Critical Finding 1 for the broader failing case); an API token never appears anywhere
  in a full `JSON.stringify` dump of IndexedDB; API config (minus token) survives reload while the
  token itself does not; `loadDemoData()` no longer clobbers a pre-set `sessionOnly`/`theme` (the
  Coder-reported fix holds).
- **Import/Export (pure-function level, since the SheetJS CDN is blocked here):** full
  `buildWorkbookSheets` → `parseWorkbook` round trip reproduces the canonical demo state exactly
  (excluding `updatedAt`); invalid enum values are reported with sheet+row+field and don't abort
  the rest of the sheet; import merge semantics are correct (existing ID updates, new ID inserts,
  absent-from-file IDs are left alone, never deleted); the generated template imports as a true
  no-op for every sheet except the (intentionally non-`EXAMPLE-`) seeded Skills catalog; month
  columns outside the configured horizon are reported and excluded, not silently dropped; renamed
  headers import correctly once mapped. With SheetJS genuinely absent, export/import controls are
  disabled with a visible banner and no uncaught exception.
- **API connector internals (once force-enabled, bypassing the missing UI — see Critical Finding
  2):** pull → field-mapped diff preview (add/update/unchanged) → cancel is a true no-op → apply
  actually upserts; a locally-edited record defaults to "keep local" in the diff, an unedited one
  defaults to applying the remote value; push never fires without an explicit button press, even
  after the preview is shown; a simulated CORS failure (`route.abort("failed")`) produces a message
  that names CORS and is textually distinct from a real HTTP 401's message (which names the status
  code and never mentions CORS); a non-array JSON response produces a clear string error, not a
  crash.
- **Performance at design scale (1,000 employees / 200 projects / 5,000 assignments, synthesized
  directly since no dev helper for this exists anywhere in the repo despite Task 19 calling for
  one):** `ROE.calc.buildIndexes` ≈ 15–19ms (budget 500ms); full `ROE.alerts.scan` ≈ 35–55ms
  (budget 2000ms); **every one of the 8 real `ROE.ui` panels renders in under 400ms** when switched
  via the actual `navigate()` function (worst observed: Optimizer ≈130ms, Alerts ≈90–100ms — both
  comfortably inside budget); ten repeated panel switches show no progressive slowdown. This
  upgrades the Coder's own "never verified through real render functions" caveat to a verified pass.
- **Accessibility (literal §9 checks, not a full WCAG audit):** every input/select/textarea on all
  8 panels (loaded with real demo data) has an associated `<label>` or `aria-label`; every nav link
  is keyboard-focusable and activates its panel on Enter; a candidate-breakdown modal is dismissible
  with Escape.
- **Global:** no PayPal/license-gate/tier-banner/paywall strings found anywhere in `index.html`
  (independent grep, confirmed empty); no `fetch`/XHR at boot other than the two CDN `<script>`
  tags; boots with zero uncaught JS exceptions from `file://`; Skills Matrix pagination is exactly
  100/page at 250 synthetic records (3 pages, correct "N record(s)" footer).
- **Purity of blocks 1–8:** grepped the exact line ranges for `ROE.const` through `ROE.io`
  (lines 123–1878) for `document.`/`window.` references. The only hits are inside the explicitly
  plan-sanctioned "thin SheetJS adapters" at the bottom of `ROE.io` (§2.2/§16 call this out by
  name as the one permitted exception). No stray DOM/window access exists in the otherwise-pure
  blocks.

---

## What I tried and could not break

- Tried committing a candidate whose availability was fully saturated across all demand months —
  it correctly scores `availability=0` and the auto-staff solver correctly refuses to allocate
  anything to it (`feasibleFraction=0` excludes it from eligibility).
- Tried forcing `requireMinSkillLevels=true` with a demand requiring a skill level nobody in the
  fixture has — correctly disqualifies with the exact reason string, not just a silent low score.
- Tried a full "Commit all" simulation across every one of the 12 demo projects' auto-staff
  proposals simultaneously (not just one project in isolation) — found zero capacity violations.
- Tried reloading after an API token was set with `authMode:"bearer"` and a live `baseUrl` — the
  token never appears in IndexedDB, and a full-`JSON.stringify` grep across every object store
  confirms it, including the `settings` record itself.
- Tried importing a workbook with a month column far outside the horizon (`2099-12`) mixed with
  valid columns — the valid columns still import correctly, the invalid one is reported and
  excluded, nothing silently vanishes.
- Tried 100 repeated calls to `rankCandidates` with the same inputs looking for any nondeterminism
  (`Math.random()` leaking in via `ROE.util.genId`, iteration-order-dependent `Set`/`Map` behavior,
  etc.) — found none; output is byte-identical every time.
- Tried synthesizing the full 1,000/200/5,000-record design-scale dataset and hammering every real
  UI panel switch, plus 10 repeated switches back-to-back looking for a memory-leak-style slowdown
  — found none; timings stayed flat and well under budget.

I did not find a way to make the app throw, corrupt data, silently drop records, or produce a
non-deterministic score. The two CRITICAL and one HIGH findings above are real, narrow, and
reproducible — not fishing expeditions — and the rest of the surface I could exercise held up.

---

## Files

- Spec files (all real, executed): `tests/specs/boot.spec.js`, `tests/specs/calc-formulas.spec.js`,
  `tests/specs/autostaff-demo.spec.js`, `tests/specs/optimizer-ui.spec.js`,
  `tests/specs/persistence.spec.js`, `tests/specs/workbook-io.spec.js`,
  `tests/specs/api-connector.spec.js`, `tests/specs/perf.spec.js`, `tests/specs/a11y.spec.js`.
- Fixtures/helpers used as-is from the Coder's scaffolding: `tests/fixtures/minimal-state.json`,
  `tests/fixtures/api-employees.json`, `tests/fixtures/api-employees-wrapped.json`,
  `tests/helpers/loadApp.js`, `tests/helpers/mockApi.js`.
- Source under test: `index.html`.
- Plan: `BUILD_PLAN.md`.
