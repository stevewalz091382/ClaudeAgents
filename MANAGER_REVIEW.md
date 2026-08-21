# MANAGER_REVIEW.md — Resource Optimization Engine (ROE)

Reviewed: `BUILD_PLAN.md` (architect), `index.html` (coder, 3,446 lines), `TEST_REPORT.md` +
`tests/specs/*` (tester). All findings below were independently reproduced by me in a real Chromium
against `file:///home/user/ClaudeAgents/index.html`, not taken on report.

---

## Verdict: **NO GO**

Two CRITICALs and two HIGHs are launch-blocking. One of the HIGHs is a defect **no one in the chain
found**. Loop back to the Coder.

The engine work is genuinely strong — formulas match §4 exactly, scoring is deterministic,
auto-staff never over-allocates, all 8 alert rules fire, perf is 20-30x inside budget. The failures
are concentrated in the **UI surface over that engine** and in **settings/state plumbing**. That is
a narrow, fixable blast radius, but it is not shippable as-is: one advertised privacy feature is
false, and one planned feature (F-12) is unreachable by a real user.

---

## Key issues, ranked

### 1. CRITICAL — Session-only mode is worse than reported: the toggle itself does not survive reload. (Owner: **Coder**)

The Tester characterized this correctly but understated it. Reproduced:

```
employees before reload: 40 | badge visible: true | after reload: 40 | settings.sessionOnly after reload: false
```

Pre-existing IndexedDB data resurfaces (as reported), **and** because `scheduleSave()` early-returns
when `sessionOnly` is true (`index.html:2218-2222`), the user's choice is never written to disk.
After reload the app comes back with `sessionOnly:false`, the badge gone, and **silently resumes
persisting**. The user is told "nothing is being saved," and the next session quietly saves
everything. This is a false privacy claim, not a missing purge step.

Violates §9 Persistence: *"Session-only mode ON → reload loses everything."*

Fix must decide the intended semantics (purge-on-enable? persist the flag out-of-band, e.g.
localStorage or a `meta` record exempt from the sessionOnly guard? both?) — that decision belongs to
the **Architect**, since the plan (§2.6) only says "all writes are skipped," which is exactly what
was built. The plan is underspecified here; the implementation is a faithful reading of a wrong spec.

### 2. CRITICAL — F-12 API connector has no configuration UI. (Owner: **Coder**)

Confirmed by enumerating every control in the rendered Data & Settings panel:

```
api-baseUrl, api-authMode, api-authHeader, api-token, api-pull, api-push
```

That is the entire API surface. Missing: any `enabled` control (all five entities default
`enabled:false` at `index.html:185-189`, so the default state is a guaranteed
`"Entity 'employees' is not enabled"` failure), any `pullPath`/`pushPath`/`responseRoot` input, and
the field-mapping UI that F-12 and §7 both name explicitly (`fieldMappings` defaults to `{}` and
nothing ever writes to it). Only `employees` has any wiring; `projects`/`demands`/`assignments`/
`skills` have none.

The Tester's nuance is correct and important: `ROE.api.pull/push/diffPull/diffPush`, dot-path
mapping, and CORS-vs-HTTP error classification all work when force-enabled. This is a missing view,
not a broken engine — which makes it cheap to fix and inexcusable to ship. Six §9 API acceptance
bullets are currently unreachable by any user without devtools.

### 3. HIGH — **Found in this review, missed by Coder and Tester:** changing Auth mode or Auth header silently wipes the configured Base URL. (Owner: **Coder**, with a coverage miss owned by **Tester**)

Stale-closure bug at `index.html:3268-3270`. All three API handlers spread a `s.api` captured at
render time, and the panel is not re-rendered after `setSettings`, so each handler reverts every
sibling field. Reproduced:

```
after setting baseUrl : {"baseUrl":"https://api.example.com/v1","authMode":"none"}
after setting authMode: {"baseUrl":"","authMode":"bearer"}      <-- baseUrl silently destroyed
```

The natural user sequence (enter URL → pick Bearer → paste token → Pull) leaves `baseUrl` empty and
produces a confusing failure. This also falsifies §9 API *"Config (minus token) survives reload"* for
any multi-field config; the Tester's spec passed only because it set a single field. **Tester: add a
multi-field settings-persistence case.** Note the horizon/ctx-tax handlers use flat patches and are
unaffected — the bug is isolated to the three API handlers.

### 4. HIGH — Weight presets round-trip normalized fractions, not raw slider values. (Owner: **Coder**)

Confirmed: sliders at 10/10/10/10, saved preset stores
`{skill:0.25, availability:0.25, seniority:0.25, discipline:0.25}` (`index.html:2869`), and the
select handler reconstructs 25/25/25/25 (`index.html:2864`). Directly violates §9 Optimizer:
*"a saved preset restores the exact weights after reload."*

Ranking is unaffected (normalization happens at read time either way), so this is a fidelity bug,
not a correctness bug — but it is a named acceptance criterion and the fix is a one-line storage
change (store the raw ints; normalize at use).

### 5. MEDIUM — **Found in this review:** F-3 CRUD is incomplete for Assignments and Skills. (Owner: **Coder**; scope call for **Architect**)

F-3 requires CRUD for "Employees, Projects, Project Demands, Assignments, Mentorships, Skills."
Built: Employees (full), Projects (full), Demands (full, with the fill-across helper), Mentorships
(create + end only, no edit/delete). **Not built at all:**

- **Assignments** — there is no assignment editor anywhere. Assignments can only be born from the
  optimizer, auto-staff, import, or API. A user cannot manually create one, change its monthly
  allocation, flip Proposed→Committed, or delete a bad one. `Assignment.source:"manual"` is defined
  in the model and unreachable. §12's own risk mitigation refers to "the demand **and assignment**
  editors" — the latter does not exist.
- **Skills** — the seeded 8-skill catalog can only be changed via workbook import. No add/edit/delete
  UI. `ROE.model.newSkill` is only ever called from the importer and the seeder.

Neither the Coder's self-report nor the Tester mentions this. It is the largest silent scope gap in
the build. Whether manual assignment editing is v1 or v2 is an **Architect** call, but shipping
without it while F-3 says otherwise is undeclared drift.

### 6. MEDIUM — **Found in this review:** the XLSX file path has never been executed by anyone. (Owner: **Tester** to flag, **Manager/user** to accept the risk)

The Tester was honest that the sandbox blocks `cdn.jsdelivr.net`, and correctly tested
`buildWorkbookSheets`/`parseWorkbook` as pure functions. But that means the four thin SheetJS
adapters (`exportWorkbookFile`, `exportTemplateFile`, `readWorkbookFile`, `isXlsxAvailable`,
`index.html:1599-1640`) and both `new Chart(...)` call sites (`index.html:2505`, `3098`) are
**unexecuted code**. N-6 ("lossless round-trip") and the §9 Import/Export block are verified at the
seam *below* the untested layer, never through a real file. Specific latent risk: `sheet_to_json`
returns mixed number/string cell types that `parseWorkbook` has only ever seen as the string forms
the pure-function tests fed it.

This needs one manual verification in a network-enabled browser before sign-off. It is not a known
defect — it is an unverified claim being presented as a pass.

---

## Loose ends

- **The Coder's own self-report overstates completion.** The commit message claims "CSV/XLSX
  import-export" and "a configurable REST API connector." CSV import does not exist (the app's own
  UI text at `index.html:3217` says so), and the connector is not configurable. Owner: **Coder** —
  report what was built, not what was planned.
- **CSV import is absent entirely.** F-11 reads "Import/export a single multi-sheet `.xlsx` workbook
  via SheetJS; also CSV per sheet." The Coder read that as export-only. Ambiguous plan text; needs an
  **Architect** ruling rather than a silent decision.
- **Import mapping UI only appears for headers auto-detection *failed* on** (`index.html:3301`). §5
  specifies a full grid of every canonical field with required-field flags. A wrong fuzzy match is
  currently unfixable by the user, and the "save mapping as a named profile in settings" clause is
  not implemented (session-only, as the Tester verified). Owner: **Coder**.
- **`horizonStart` is hardcoded to `"2026-01"`** (`index.html:172`) where §2.4 says "default =
  current calendar year." Correct by luck in 2026, wrong in January 2027. Also accepts any string
  with no validation — I stored `"not-a-month"` through the real input; no crash, but the horizon is
  silently garbage. Owner: **Coder**.
- **"Monitor" action is missing** from the optimizer candidate cards. §7 specifies "Commit / Monitor
  / Review"; only Commit and Review exist. Zero occurrences of "Monitor" in the file. Either build it
  or have the **Architect** strike it.
- **Committing a zero-availability candidate creates an empty assignment.** `commitCandidate`
  (`index.html:2930-2947`) allocates `min(need, free)` per month; if free is 0 everywhere the result
  is an assignment with `allocationByMonth = {}` and no warning. Safe (never over-allocates) but
  produces junk records. Owner: **Coder**, low priority.
- **Task 19's dev helper was never built.** The Tester synthesized the 1,000/200/5,000 dataset
  themselves and noted its absence. Perf is verified regardless, so this is a missing tool, not a
  missing result. Owner: **Coder**.
- **The three LOW items in TEST_REPORT.md are correctly characterized.** I confirmed the CSV-export
  button is gated on `v.xlsx` at `index.html:3222` despite `buildCsvForSheet` never touching
  `window.XLSX`; `STORE.subscribe`/`notify` has zero subscribers; and `ROE.const.ADJACENCY` adds the
  reverse edges the plan's §3 table omits (the code is right, the **plan** is the thing that is
  asymmetric — Architect should correct §3 so the artifact and the spec agree).
- **Harness portability.** `tests/playwright.config.js` assumes `npx playwright install` can reach
  `cdn.playwright.dev`. It cannot here. The Tester worked around it with a local override pointing at
  `/opt/pw-browsers/chromium-1194/...`, and that override is **not committed** — the harness as
  checked in does not run in this environment. Owner: **Tester**.

---

## Bundling guidance

**Fix pass 1 (blocking, must be re-tested before sign-off):** issues 1-4. All four are small,
localized edits. Issue 1 needs an Architect ruling on intended semantics first.

**Same pass, cheap:** LOW #5 (ungate the CSV export button — one condition), the `s.api` stale
closure is the same edit as issue 3, and the `horizonStart` default/validation. These are one-liners
sitting in files already being opened; deferring them costs more than doing them.

**Defer to v2 / explicit scope decision:** issue 5 (Assignments + Skills CRUD) and CSV import — both
are real feature work, and both need the Architect to decide whether F-3/F-11 are being met or
amended. Do not let them ship silently un-met.

**Defer:** LOW #4 (dead pub/sub — architectural smell, no user-facing symptom today) and LOW #6
(plan-text correction, Architect's file to change, not the Coder's).

**Before final sign-off, regardless of code fixes:** one manual pass in a network-enabled browser
exercising real XLSX export → clear → re-import and both Chart.js render paths. That is the only
material coverage hole left, and no amount of re-running the current suite closes it.

---

## Chain assessment

- **Architect:** plan is unusually good — formulas precise enough to test against, decisions made
  rather than deferred, risks named. Two real defects: §2.6's session-only spec is underspecified in
  exactly the way that produced CRITICAL #1, and §3's adjacency table is not symmetric as printed.
- **Coder:** engines are excellent and match the plan formula-for-formula, with clean block purity
  (independently confirmed: no DOM access outside the sanctioned SheetJS adapters). The UI layer is
  where it thins out — a whole planned feature has no view, two entities have no CRUD, and the
  settings handlers have a stale-state bug. Self-report claimed more than was delivered.
- **Tester:** strong, honest work. 68 real executed tests, accurate root-cause analysis on every
  finding I checked, and explicit about what the sandbox prevented rather than papering over it. Two
  gaps: no multi-field settings-persistence test (which is how issue 3 escaped), and no coverage of
  F-3 CRUD completeness for Assignments/Skills — the suite tested what exists rather than checking
  the requirement list for what does not.
