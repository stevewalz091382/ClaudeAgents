# TEST_REPORT.md — Resource Optimization Engine (ROE)

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
