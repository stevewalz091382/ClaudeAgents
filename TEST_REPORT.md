# TEST_REPORT.md — Resource Optimization Engine (ROE)

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
