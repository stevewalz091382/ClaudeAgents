# MANAGER_REVIEW.md — Resource Optimization Engine (ROE)

---

# ROUND 2 REVIEW (fix loop 2 verification) — 2026-08-21

Reviewed: `BUILD_PLAN.md` §9, `MANAGER_REVIEW.md` round-1 (preserved below), `TEST_REPORT.md`
(rounds 1 + 2), and `index.html` at commit `47cad26`. Every finding below was independently
reproduced by me in a real Chromium against `file:///home/user/ClaudeAgents/index.html`. I did not
take the Tester's or the Coder's characterization on report — I re-ran the committed suite myself
(**90 passed / 2 failed**, matching the Tester exactly) and wrote seven of my own probes.

## Verdict: **GO WITH FIXES** — conditional, with one mandatory blocking fix

The fix is **not optional and cannot be documented away.** See "Why not a documented limitation"
below. If the final loop does not close it, the fallback is to **remove the session-only toggle from
the UI entirely** rather than ship it in its current state.

Everything outside `ROE.store`'s ~150-line persistence region is verified healthy: 90/90 committed
tests pass, all three round-1 blockers are genuinely fixed under my own adversarial re-runs, and the
calc/score/alerts/mentor engines are untouched since round 1. The blast radius is now a **single
region of a single module**, and the fix is a handful of lines. That is why this is GO WITH FIXES
and not another NO GO — there is no structural doubt left, only one unfinished feature.

---

## Key issues, ranked

### 1. BLOCKING — Session-only mode has **three** failure modes, not one. Two of them destroy data. (Owner: **Coder** to implement; **Architect** owns the root cause)

The Tester found one of these (over-persistence) and rated it HIGH on the reasoning that "nothing is
being destroyed this time." **That severity reasoning is wrong.** I found two additional flows in the
same code path that do destroy data. All three share one root cause: after fix loop 2 there are now
**two independent booleans — `state.settings.sessionOnly` and `hydrated` — that are allowed to
disagree**, and neither the save path nor the UI badge reconciles them.

`setSessionOnly()` (`index.html:2352-2360`) writes the preference and calls `scheduleSave()` but
**never touches `hydrated`**. `hydrated` is only ever assigned inside `load()` and `clearAll()`. So:

**(a) Over-persistence — the Tester's finding. Confirmed.** Boot normally (`hydrated = true`), check
session-only, add a record, uncheck. Both guards in `scheduleSave()` pass and the "private" record is
written to disk after the 400ms debounce, with no reload. My repro:

```
MGR-1 {"before":40,"sessionOnlyFlag":true,"duringOn":40,"after":41,"leaked":true}
```

This directly falsifies UI copy the Coder wrote in this very commit (`index.html:3316`): *"nothing is
written to IndexedDB until you reload the page."* Reproduces identically from a blank slate.

**(b) NOT FOUND BY ANYONE — deletions made during the "nothing is being saved" window are committed
to disk on toggle-off.** Same mechanism, opposite data. The user turns on a mode that promises
nothing will be saved — which is exactly why people turn such a mode on: to experiment destructively
in safety — deletes 20 of 40 employees, then unchecks the box. `persist()` calls
`DB.replaceAll("employees", state.employees)` with the 20-record array. The 20 deleted records are
**gone from disk permanently**:

```
MGR-5 {"before":40,"duringOn":40,"afterToggleOff":20,"afterReload":20}
```

This is the same class of defect as round 1's CRITICAL — silent, unrecoverable destruction of records
the user never explicitly deleted from storage — merely reached by a different door. The Tester's
"nothing is being destroyed this time" conclusion does not survive contact with a destructive edit.

**(c) NOT FOUND BY ANYONE — the "Session only — nothing is being saved" badge lies in the dangerous
direction, and a full session of work is silently lost.** After a session-only reload, `hydrated` is
`false`. Uncheck the box: `updateSessionBadge()` (`index.html:2520-2524`) binds visibility to
`settings.sessionOnly` only, so **the badge disappears** — the app's one global persistence indicator
now says "your work is being saved." It is not: `hydrated` is still `false`, so every write silently
no-ops until a reload. My repro — 41 records of work, badge hidden, nothing on disk, everything gone
after reload:

```
MGR-7 {"badgeVisible":false,"badgeText":"Session only - nothing is being saved",
       "memCount":41,"idbHasWork":false,"workSurvivesReload":false}
```

The settings-panel hint text does explain the reload requirement, but a paragraph in a settings panel
does not substitute for the global indicator that is actively contradicting it.

**Root cause is architectural, and it is the Architect's.** `BUILD_PLAN.md` §2.6 still says only
*"when on, all writes are skipped"* — unamended after three loops. It has never specified what
happens when the toggle goes **off**, which is where every one of these bugs lives. This is the third
consecutive loop in which a defect has been generated by that one unspecified sentence. Amend §2.6
before the Coder touches this again, or loop four will produce a fourth variant.

**Proportionate fix (one small edit, closes all three at once):** make the checkbox reload-gated —
on change, write the preference and reload the page (or block the change behind an explicit "Reload
to apply" action). `sessionOnly` and `hydrated` then can never diverge within a session, the
already-written UI copy becomes true, and (a), (b), and (c) all disappear. Do not patch the three
symptoms individually.

### 2. Tester severity-analysis miss. (Owner: **Tester**)

The finding itself is excellent work — correctly located, correctly root-caused, reproduced from a
blank slate, and honest about what the sandbox blocks. But the severity call drove a
"GO WITH FIXES, nothing is destroyed" recommendation that two of my probes falsify in under five
minutes each. The gap is method, not diligence: the Tester tested **additions** during the
session-only window and generalized to "over-persistence, non-destructive," without testing
**deletions** or **the state of the badge after toggle-off**. When a guard flag is found to be
reachable in an unintended state, the next question is what *else* rides on that flag — here, the
global "nothing is being saved" indicator did, and it fails unsafely.

### 3. Confirmed genuinely fixed — I re-verified all three, independently.

Round-1 CRITICAL (toggle-off after reload wiping IndexedDB), the Clear-all leftover preference
record, and the horizon month-range validation are all real fixes, not test-shaped ones. The
committed suite runs 90/90 minus the Tester's own two new failing probes, and `git diff 95e9df5
47cad26 -- index.html` is empty, confirming the Tester changed no production code. No regressions
anywhere in calc, score, alerts, mentor, io, api, a11y, or perf. I also re-checked N-4 directly: an
API token set via `ROE.api.setToken` appears nowhere in any object store after a forced save.

---

## Why not a documented limitation

The option of shipping this as a known limitation with a one-line mitigation ("reload after
unchecking") was considered and is **rejected**. A release note does not help a user who finds 20 of
their 40 records gone (b), and it cannot be read by a user whose badge told them saving was on (c).
Documented limitations are appropriate for *inconvenience*; they are not appropriate for **silent,
unrecoverable data loss with a misleading indicator**. The UI-change variant of the mitigation — make
the toggle require a reload — is not a mitigation at all, it *is* the fix, and it is small. Spend the
final loop on it.

---

## Loose ends

- **Deferred MEDIUMs re-verified as unchanged, correctly characterized, and correctly out of scope**
  for this pipeline's remaining budget. I confirmed each in the current file rather than assuming:
  Assignment CRUD absent (`source:"manual"` still unreachable; assignments only born from
  optimizer/import/api), Skill CRUD absent (`newSkill` called only by the importer and seeder), CSV
  import absent (the app's own text at `index.html:3295` says so), `STORE.subscribe`/`notify` still
  has **zero** callers, and `window.XLSX`/`window.Chart` remain unexecuted in this sandbox. None are
  new; none are regressions. They need an explicit **Architect** ruling on F-3/F-11 in a v2 pass, not
  a silent pass here.
- **"Monitor" action still absent** from optimizer candidate cards — zero occurrences of the string
  in the file, against §7's "Commit / Monitor / Review." Unchanged since round 1. Architect should
  strike it from §7 or schedule it.
- **`horizonStart` still hardcoded `"2026-01"`** (`index.html:172`). Correct by luck today; wrong on
  1 Jan 2027. §2.4 says "current calendar year." Owner: **Coder**, cheap, still open.
- **Clear-all now silently resets the session-only preference to OFF** and resumes persistence. This
  is a deliberate round-2 decision to satisfy the literal §9 wording, and `clearAllFlow` does call
  `renderAll()` so the checkbox and badge do update — acceptable, but it means a privacy toggle can
  be turned off by an action the user took for an unrelated reason. Worth one line in the About text.
- **The unverified live-CDN / XLSX / Chart.js path is unchanged and still the only material coverage
  hole** outside issue 1. One manual pass in a network-enabled browser (real xlsx export → clear →
  re-import, plus both `new Chart(...)` call sites) is still required before final sign-off,
  regardless of what the last code loop does.
- **Harness portability still unfixed.** `tests/playwright.config.js` as committed cannot launch a
  browser here; `tests/pw.local.config.js` remains uncommitted. I had to use it too. Owner:
  **Tester** — third loop this has been logged.

---

## Chain assessment (round 2)

- **Architect:** the plan remains strong, but §2.6 has now generated three consecutive loops of
  defects by never specifying toggle-off semantics, and it still has not been amended. That is the
  single highest-leverage document change left in this build.
- **Coder:** the round-2 fixes are real, well-commented, and the `hydrated` guard is the right idea —
  it just was not carried through to the two other places that depend on the same state. Work quality
  is good; the recurring pattern is fixing the reported instance rather than the state machine that
  produced it.
- **Tester:** the strongest link in the chain three rounds running — found a defect the Coder's own
  tests structurally could not, reproduced it from a blank slate, and was explicit about
  environmental limits. The one miss is severity analysis (see issue 2), and it mattered, because it
  fed a "not destructive" recommendation that is not accurate.

---
---

# ROUND 1 REVIEW (preserved, unchanged)

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
