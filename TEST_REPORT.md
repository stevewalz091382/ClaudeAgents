# TEST_REPORT.md — Weighted Decision Engine (`index.html`)

Tested by: Tester agent. Method: static code review plus live rendering/interaction testing in a real Chromium instance (Playwright, `executablePath: /opt/pw-browsers/chromium`) loaded via `file://`, opened directly against `/home/user/ClaudeAgents/index.html` (no server). All findings below were reproduced live, not inferred from source alone; the driver scripts referenced are saved under `/tmp/claude-0/-home-user-ClaudeAgents/2c19d920-0d83-5ba7-a188-5f5447493b4c/scratchpad/pw/` if reruns are needed.

Verdict up front: the calculation engine, persistence, gating, export/import, keyboard flow, and responsive layout are all solid and match the BUILD_PLAN spec closely — I could not break the math, the focus/caret handling (A15), or the keyboard-only flow (A17). But there are two CRITICAL defects that undermine trust in the app on literally every session, plus a handful of lower-severity issues.

---

## CRITICAL

### C1. Every "hidden" banner/message that also carries `.banner` or `.badge-warning` is permanently visible, regardless of `hidden` state — confirmed on 7 elements, not just the 1 originally spotted

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
Documented under C1's downstream effects; listed separately here only because it's independently an N5 (keyboard navigability) concern: a screen-reader or keyboard user starting a fresh session tabs into "Dismiss" (for a corruption banner that doesn't exist) and "Export session JSON" (for a quota error that hasn't happened) before reaching the app's real controls. Will resolve automatically once C1 is fixed.

---

## What I verified working correctly (i.e., could not break)

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

## Summary

| Severity | Count | Items |
|---|---|---|
| CRITICAL | 2 | C1 (hidden/display CSS bug, 7 elements), C2 (multi-rater-off silently keeps blending hidden rater data) |
| HIGH | 0 | — |
| MEDIUM | 1 | M1 (dual "Recommended" badge on ties — judgment call) |
| LOW | 2 | L1 (decimal truncation on hostile score input), L2 (dead controls in tab order, consequence of C1) |

Everything else I attempted to break — the calculation engine (A5–A7, A12–A13), persistence (A8, A18), export gating and round-trip (A9–A11), orphan pruning (A19), the 380px responsive layout (A16), the full keyboard-only flow (A17), print output (A20), and focus/caret stability while typing (A15, the item flagged as highest-risk) — held up under adversarial testing. The two CRITICAL findings should block GO until fixed: C1 because it fires on every single session with no trigger required, and C2 because it silently produces a wrong ranked recommendation — the one thing this entire application exists to get right — with no way for the user to notice.
