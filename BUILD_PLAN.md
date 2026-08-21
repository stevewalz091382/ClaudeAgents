# BUILD PLAN — Resource Optimization Engine (ROE)

## Objective

Build a single self-contained `index.html` web app that lets a staffing/resource manager import their people and projects, see time-phased utilization, and get deterministic, explainable staffing recommendations — functionally comparable to the IPRO reference app, with our own layout, our own data, and no backend of any kind.

---

## 1. Requirements

### Functional

- [ ] **F-1** Single file `index.html` runs from `file://` or any static host with no build step and no Node at runtime.
- [ ] **F-2** Eight panels: Overview, Skills Matrix, Projects, Optimizer, Mentorship, Timeline, Alerts, Data & Settings. (Platform/License Usage is **v2, out of scope**.)
- [ ] **F-3** CRUD for Employees, Projects, Project Demands, Assignments, Mentorships, Skills.
- [ ] **F-4** Time-phased allocations: every assignment and every project demand stores a **per-month percentage map**, not a flat pct + date range.
- [ ] **F-5** Deterministic weighted optimizer producing ranked candidates per open demand, each with a full factor breakdown. No LLM, no network call, same input → same output.
- [ ] **F-6** Tunable optimizer weights via sliders, normalized, savable as a named preset.
- [ ] **F-7** One-click commit per candidate, plus "Auto-staff project" that respects capacity ceilings.
- [ ] **F-8** Context-switch tax reduces effective capacity as concurrent project count rises; configurable rate and cap.
- [ ] **F-9** Multi-factor burnout/overload alerts engine with configurable thresholds and a "Run scan" action.
- [ ] **F-10** Mentorship pairing suggestions (skill gap + seniority delta + discipline + mentor spare capacity), max 2 mentees per mentor.
- [ ] **F-11** Import/export a single multi-sheet `.xlsx` workbook via SheetJS; also CSV per sheet. Column-mapping UI for non-canonical headers. Downloadable blank templates generated in-browser.
- [ ] **F-12** Optional REST API connector: configurable base URL, auth, per-entity path, JSON array response, field-mapping UI, pull + explicit push with a preview diff.
- [ ] **F-13** Persistence in IndexedDB with a visible "Clear all data" control and a session-only mode toggle.
- [ ] **F-14** One-click demo/seed dataset, one-click clearable.

### Non-functional

- [ ] **N-1** Handles 1,000 employees / 200 projects / 5,000 assignments without freezing. No virtualization; use pagination + memoized indexes instead.
- [ ] **N-2** Evergreen browsers only (Chrome/Edge/Firefox/Safari current). No IE, no transpilation, ES2020+ allowed.
- [ ] **N-3** Dark theme (matches reference palette family). Keyboard navigable, all controls labeled. No formal WCAG audit.
- [ ] **N-4** Secrets (API tokens) live in memory only, for the session. Never written to IndexedDB, localStorage, sessionStorage, or exports.
- [ ] **N-5** Core logic exposed as pure functions on a single global namespace so it is testable from a headless browser.
- [ ] **N-6** Lossless round-trip: export → import reproduces byte-equivalent canonical state (excluding timestamps).

### Explicit non-goals (v1)

- Platform/License Usage panel. Cost or location factors in scoring. PTO/leave data. OAuth2. Multi-user, auth, or server-side anything. Free-tier banners, license gates, payment buttons — none of the reference's monetization mechanics are replicated.

---

## 2. Architecture

### 2.1 Shape

One HTML document, one `<style>` block, a small number of `<script>` blocks. Vendored via CDN `<script>` tags: **Chart.js** (charts) and **SheetJS/xlsx** (workbook I/O).

**Trade-off:** CDN keeps the file small and matches the reference, but makes the app non-functional offline on first load and dependent on a third party. Mitigation: feature-detect both libraries on boot; if absent, disable the charts and import/export UI with an inline explanatory banner rather than throwing. Everything else keeps working. Record this in the in-app "About" note.

### 2.2 Script block layout (order matters)

| Block | Namespace | Contents |
|---|---|---|
| 1 | `ROE.const` | Enums, adjacency table, default settings, schema version |
| 2 | `ROE.util` | Pure helpers: month keys, clamp, deep equal, id gen, CSV escape |
| 3 | `ROE.model` | Canonical record factories + validators (pure) |
| 4 | `ROE.calc` | ctxTax, capacity, utilization, index builders (pure) |
| 5 | `ROE.score` | Optimizer scoring + auto-staff solver (pure) |
| 6 | `ROE.alerts` | Rules engine (pure) |
| 7 | `ROE.mentor` | Pairing engine (pure) |
| 8 | `ROE.io` | Workbook build/parse, field mapping, template gen (pure except SheetJS calls) |
| 9 | `ROE.api` | Connector: fetch, map, diff, push (impure, isolated) |
| 10 | `ROE.db` | IndexedDB wrapper (impure, isolated) |
| 11 | `ROE.store` | In-memory state, mutations, subscribe/notify |
| 12 | `ROE.ui` | Render functions per panel, event wiring, bootstrap |

**Key decision:** blocks 1–8 must contain **zero DOM access and zero I/O**. They take state in, return values out. This is the entire testing strategy (see §6). The Coder must not reach into `document` from those blocks.

### 2.3 Data flow

```
IndexedDB ──load──> ROE.store (in-memory canonical state)
XLSX/CSV ──ROE.io.parse──> mapping UI ──> validate ──> merge preview ──> store
REST API ──ROE.api.pull──> field map ──> validate ──> diff preview ──> store
                                                     store ──ROE.api.push──> REST API (explicit, previewed)
store ──> ROE.calc.buildIndexes() (memoized, invalidated on mutation)
        ──> ROE.score / ROE.alerts / ROE.mentor ──> ROE.ui render
store ──save (debounced 400ms)──> IndexedDB
```

`buildIndexes()` produces `{ byEmployeeMonth: Map<empId, Map<monthKey, {pct, projectIds:Set}>>, byProjectMonth, demandFill }`. Rebuilt lazily on a dirty flag, never inside a render loop. This is how N-1 is met at 5,000 assignments.

### 2.4 Time model

- Planning horizon is a settings-level list of month keys, format `YYYY-MM`, contiguous, default = current calendar year Jan–Dec, length configurable 6–36 months.
- All allocation maps are `{ "2026-03": 50, "2026-04": 50 }`. Absent key = 0%. Values are integers 0–100.
- **Trade-off:** `YYYY-MM` string keys instead of the reference's `startMo`/`endMo` integers. Slightly larger payloads, but supports multi-year horizons and makes the workbook's wide month columns self-describing.

### 2.5 Skill level scale — DECISION

**Canonical storage is an integer 0–5.** Named strings are *display only*, derived from a fixed map, never stored, never the source of truth:

`0 None · 1 Basic · 2 Intermediate · 3 Proficient · 4 Advanced · 5 Expert`

Import accepts either the integer or the label (case-insensitive) and normalizes to the integer. Export writes the integer in a `Level` column and the label in an adjacent `LevelLabel` column that is ignored on re-import. This satisfies "pick one" — there is exactly one stored representation.

### 2.6 Persistence

- IndexedDB database `roe`, version 1, object stores: `employees`, `projects`, `demands`, `assignments`, `mentorships`, `skills`, `settings` (single record, key `"app"`), `meta` (schemaVersion).
- On boot: open DB → if `meta.schemaVersion` mismatches, run the migration ladder; if none exists, show the empty state with "Load demo data".
- **Session-only mode toggle** in Data & Settings: when on, all writes are skipped and a persistent badge reads "Session only — nothing is being saved".
- **Clear all data** button in the panel header, red, two-step confirm typing `CLEAR`, wipes all object stores and reloads to empty state.
- API tokens live on `ROE.api._session` (a closure variable), are excluded from the settings record by construction (the settings serializer whitelists fields), and are never included in any export.

---

## 3. Canonical data model

IDs are strings. All records carry `id` and `updatedAt` (ISO 8601).

```js
Employee {
  id, name, email,
  level: "Junior"|"Mid-Level"|"Senior"|"Principal",
  discipline: Discipline,          // see enum below
  office,                          // free text, e.g. "Omaha, NE"
  businessGroup: "Transportation"|"Buildings"|"Water"|"Federal"|"Energy",
  targetUtil,                      // int 0..100, default 85
  mentorRole: "Mentor"|"Mentee"|"Peer"|"None",
  active: bool,
  notes
}

Skill { id, code, name, category }          // seeded: REVIT, CIVIL3D, AUTOCAD, GIS, PYTHON, NAVIS, BLUEBEAM, PM

EmployeeSkill { employeeId, skillId, level }  // level int 0..5; stored as a flat array in store.employeeSkills

Project {
  id, name, client,
  market: "Transportation"|"Buildings"|"Water"|"Federal"|"Energy",
  discipline: Discipline,          // primary discipline
  phase: "Planning"|"Concept"|"Schematic"|"DD"|"CD"|"CA"|"Final Design"|"Implementation",
  budget,                          // number, informational KPI only
  bimLevel: "BIM Level 0".."BIM Level 3",
  teamMin, teamMax,                // advisory, drives an Overview KPI and an alert
  priority: 1..5,                  // 1 = highest
  status: "Active"|"Pending"|"On Hold"|"Complete",
  software: [skillId],             // informational; NOT the optimizer requirement
  notes
}

Demand {                           // an open staffing need on a project; the optimizer's unit of work
  id, projectId, title,            // e.g. "Civil Designer"
  discipline: Discipline,
  minLevel: "Junior"|"Mid-Level"|"Senior"|"Principal",
  requiredSkills: [ { skillId, minLevel: 0..5, weight: 1|2|3 } ],
  openings: int >= 1,
  allocationByMonth: { "YYYY-MM": pct }   // per opening
}

Assignment {
  id, projectId, employeeId,
  demandId | null,
  allocationByMonth: { "YYYY-MM": pct },
  status: "Proposed"|"Committed",
  source: "manual"|"optimizer"|"auto-staff"|"import"|"api",
  scoreSnapshot: number|null              // score at time of commit, for audit
}

Mentorship {
  id, mentorId, menteeId, focusSkillId,
  sharedProjectId | null,
  frequency: "Weekly"|"Bi-Weekly"|"Monthly",
  score: 0..100, compat: "High"|"Medium"|"Low",
  status: "Active"|"Pending"|"Ended"
}

Settings {
  schemaVersion, horizonStart: "YYYY-MM", horizonMonths: int,
  weights: { skill, availability, seniority, discipline },   // normalized to 1.0
  presets: [ { name, weights } ],
  ctxTaxPerExtraProject: 7, ctxTaxCapPct: 30, ctxCap: 4,
  alertThresholds: { overallocPct:100, sustainedMonths:2, targetSlackPct:10, benchGapPct:25, benchMonths:3 },
  requireMinSkillLevels: false,
  sessionOnly: false,
  theme: "dark",
  api: { baseUrl, authMode, authHeaderName, entities:{...}, fieldMappings:{...} }  // NO token field, ever
}
```

`Discipline` enum: `Civil, Architecture, MEP, Structural, Environmental, VDC, Data/Analytics, Landscape, Geotechnical`.

**Discipline adjacency table** (used by the optimizer, symmetric, everything not listed is "unrelated"):

```
Civil          ↔ Geotechnical, Environmental, Landscape
Architecture   ↔ VDC, Structural, Landscape
MEP            ↔ Structural, VDC
Structural     ↔ Civil, Architecture, MEP
Environmental  ↔ Water-adjacent Civil, Geotechnical
VDC            ↔ Architecture, MEP, Data/Analytics
Data/Analytics ↔ VDC, Environmental
Landscape      ↔ Architecture, Civil
Geotechnical   ↔ Civil, Structural, Environmental
```

---

## 4. Core formulas (implement exactly as written)

### 4.1 Context-switch tax

```
ctxTaxPct(n) = clamp( ctxTaxPerExtraProject * (n - 1), 0, ctxTaxCapPct )
```
`n` = count of distinct projects the employee has a non-zero allocation on in that month. Defaults: `ctxTaxPerExtraProject = 7` (slider 5–15, matching the reference's stated range), `ctxTaxCapPct = 30`. `n <= 1` → 0.

### 4.2 Capacity

```
effectiveCapacity(emp, month) = emp.targetUtil * (1 - ctxTaxPct(n(emp,month)) / 100)
committed(emp, month)         = Σ allocation pct across all assignments in that month
netCap(emp, month)            = effectiveCapacity - committed          // may go negative
free(emp, month)              = max(0, netCap)
utilization(emp, month)       = committed                              // reported raw, vs targetUtil
```

For a *candidate evaluation*, `n` is the **projected** count: existing distinct projects that month, plus 1 if this project is not already among them.

### 4.3 Optimizer sub-scores (each 0–100)

**Skill match.** For each `requiredSkills` row, with employee level `e` and required `m`, `gap = e - m`:

| gap | sub-score |
|---|---|
| >= +2 | `max(85, 100 - 5*(gap-1))` (over-qualification damping) |
| +1 | 100 |
| 0 | 100 |
| -1 | 60 |
| -2 | 30 |
| <= -3 | 0 |

`skillScore = Σ(sub * weight) / Σ(weight)`. If `requiredSkills` is empty, `skillScore = 70` (neutral). If `settings.requireMinSkillLevels` is true, any `gap < 0` disqualifies the candidate (excluded from the list with reason "below minimum skill level").

**Availability.** For each month `m` where `demand.allocationByMonth[m] > 0`:
```
fit(m) = min(1, free(emp, m) / demand.allocationByMonth[m])
availabilityScore = 100 * mean(fit(m))
feasibleFraction  = mean(fit(m))            // reused by auto-staff
```

**Seniority fit.** Ordinals `Junior=1, Mid-Level=2, Senior=3, Principal=4`; `d = empOrd - demandMinOrd`:

| d | score |
|---|---|
| 0 | 100 |
| +1 | 85 |
| >= +2 | 65 |
| -1 | 50 |
| <= -2 | 15 |

**Discipline match.** Exact = 100, adjacent (§3 table) = 65, unrelated = 25.

### 4.4 Composite

```
base = w.skill*skillScore + w.availability*availabilityScore
     + w.seniority*seniorityScore + w.discipline*disciplineScore
```
Default weights, must sum to 1.0: **skill 0.35, availability 0.30, discipline 0.20, seniority 0.15**. Sliders are 0–100 ints, normalized at read time; if all are 0, fall back to defaults.

Modifiers, applied additively then clamped to `[-15, +10]` in total:

| Modifier | Value | Condition |
|---|---|---|
| Continuity | +4 | Employee already has a committed assignment on this project |
| Mentorship | +5 | Candidate is a Mentor with < 2 active mentees and a mentee is staffed on this project, OR candidate is a Mentee whose mentor is staffed on this project |
| Overload | -10 | Committing would push projected concurrent projects above `ctxCap` in any demand month |
| Bench relief | +3 | Employee's mean committed across demand months < `targetUtil - benchGapPct` |

```
matchScore = clamp( round(base + clampedModifiers), 0, 100 )
```

Every candidate row must render the four sub-scores, their weighted contributions, and each applied modifier with its reason string. No score may appear in the UI without its breakdown reachable in one click.

### 4.5 Auto-staff solver

Greedy, deterministic, explainable:

1. Order demands by `project.priority` asc, then total FTE desc, then `demand.id` asc.
2. For each demand, for each of its `openings`: score all eligible employees, sort by `matchScore` desc, tie-break by `feasibleFraction` desc, then `employee.id` asc.
3. Take the top candidate with `feasibleFraction > 0`. Allocate `min(demand.pct(m), free(emp,m))` per month — **never exceeding effective capacity**, i.e. the solver may under-fill but must never over-allocate.
4. Recompute indexes (the pick changes ctxTax for later picks — this must be re-derived, not cached across picks).
5. Emit results as **Proposed** assignments in a preview table with per-row accept/reject and a single "Commit all" button. Nothing is written until the user commits.
6. Unfilled or partially filled demands are listed with the reason (no capacity / no skill match / all candidates below minimum).

### 4.6 Alerts rules

Severities: CRITICAL, HIGH, MEDIUM, LOW. Each alert carries `{id, severity, ruleId, subjectType, subjectId, monthKeys[], message, suggestedAction}`.

| Rule | Condition | Severity |
|---|---|---|
| `SUSTAINED_OVERALLOC` | `committed(m) > overallocPct` for `>= sustainedMonths` consecutive months | HIGH |
| `OVER_TARGET` | `committed(m) > targetUtil + targetSlackPct` for >= 3 months | MEDIUM |
| `CTX_OVERLOAD` | concurrent projects > `ctxCap` in any month | MEDIUM; > `ctxCap + 2` → HIGH |
| `BURNOUT_COMPOSITE` | see below | CRITICAL >= 70, HIGH 50–69, MEDIUM 30–49 |
| `BENCH_RISK` | `committed(m) < targetUtil - benchGapPct` for >= `benchMonths` months | LOW |
| `UNSTAFFED_DEMAND` | demand fill < 100% in any month | HIGH if `priority <= 2`, else MEDIUM |
| `TEAM_SIZE` | distinct assigned employees in a month outside `[teamMin, teamMax]` | LOW |
| `SKILL_GAP` | no active employee meets a demand's required skill minimums | MEDIUM |

```
burnoutScore = 100 * ( 0.5 * (sustainedOverallocMonths / horizonMonths)
                     + 0.3 * min(1, (peakCommitted - 100) / 50)      // 0 if peak <= 100
                     + 0.2 * min(1, maxConcurrentProjects / 6) )
```
PTO/leave is explicitly **not** a factor (no data source). "Run live scan" re-evaluates all rules with a progress indicator; results are not persisted, they are always derived.

### 4.7 Mentorship pairing

For an unpaired mentor/mentee candidate pair:
```
pairScore = 0.40 * skillGapValue + 0.25 * seniorityDeltaValue
          + 0.20 * disciplineValue + 0.15 * mentorSpareCapacityValue
          + 5 if they share a project (applied after, clamp 0..100)
```
- `skillGapValue`: 100 * mean over the focus skill(s) of `clamp((mentorLevel - menteeLevel) / 3, 0, 1)`; a gap of 3+ levels is ideal, 0 or negative gap = 0.
- `seniorityDeltaValue`: delta of 1 → 70, 2 → 100, 3 → 80, 0 or negative → 0.
- `disciplineValue`: exact 100, adjacent 60, unrelated 20.
- `mentorSpareCapacityValue`: `100 * (1 - activeMentees/2)`; a mentor at 2 active mentees is **excluded entirely**.
- `compat`: High >= 75, Medium 50–74, Low < 50. Pairings below 35 are not suggested.

---

## 5. Workbook / CSV schema

One workbook, sheet names exact and case-sensitive. Month columns are literal `YYYY-MM` headers and must fall inside the settings horizon on import (out-of-horizon columns are reported and skipped, not silently dropped).

### `Meta`
| Key | Value |
|---|---|
| SchemaVersion | 1 |
| ExportedAt | ISO 8601 |
| HorizonStart | 2026-01 |
| HorizonMonths | 12 |

### `Employees`
`EmployeeID | Name | Email | Level | Discipline | Office | BusinessGroup | TargetUtil | MentorRole | Active | Notes`

### `Skills`
`SkillID | Code | Name | Category`

### `EmployeeSkills` (long format — survives custom skills)
`EmployeeID | SkillID | Level | LevelLabel(ignored on import)`

### `Projects`
`ProjectID | Name | Client | Market | Discipline | Phase | Budget | BIMLevel | TeamMin | TeamMax | Priority | Status | Software(semicolon-separated SkillIDs) | Notes`

### `ProjectDemands` (wide months)
`DemandID | ProjectID | Title | Discipline | MinLevel | Openings | RequiredSkills | 2026-01 | 2026-02 | ...`

`RequiredSkills` encoding: `SKILLID:minLevel:weight` joined by `;` — e.g. `CIVIL3D:3:2;AUTOCAD:2:1`.

### `Assignments` (wide months)
`AssignmentID | ProjectID | EmployeeID | DemandID | Status | Source | ScoreSnapshot | 2026-01 | ...`

### `Mentorships`
`MentorshipID | MentorID | MenteeID | FocusSkillID | SharedProjectID | Frequency | Score | Compat | Status`

### Template layout

"Download template" emits the same workbook with headers, the `Meta` sheet filled from current settings, month columns generated from the horizon, all `Skills` rows seeded, and exactly one commented example row per sheet marked with `EXAMPLE-` ID prefixes. Rows whose ID starts with `EXAMPLE-` are skipped on import. CSV export writes one file per sheet with identical headers.

### Column-mapping UI

If a sheet's headers do not match canonically, show a mapping grid: left column = canonical field (required fields flagged), right column = a dropdown of detected headers plus `<ignore>`. Auto-suggest by case-insensitive, punctuation-stripped fuzzy match. Mapping is remembered per session and can be saved into settings under a named profile.

### Import merge semantics

Match on ID. Existing ID → update, new ID → insert, missing ID → **left alone** (never deleted by import). Blank ID → generate one. Import always shows a preview count of insert/update/skip/error before applying. Validation errors are listed per row with the sheet, row number, and field.

---

## 6. API connector

```js
apiConfig = {
  baseUrl: "https://api.example.com/v1",
  authMode: "none" | "apiKey" | "bearer",
  authHeaderName: "X-API-Key",          // only when authMode === "apiKey"
  // token is NEVER in this object — it lives in ROE.api._session.token
  timeoutMs: 15000,
  entities: {
    employees:   { enabled, pullPath: "/employees", responseRoot: "data.items", pushPath: "/employees", pushMethod: "POST"|"PUT", pushMode: "bulk"|"perRecord", idField: "id" },
    projects:    { ... }, demands: { ... }, assignments: { ... }, skills: { ... }
  },
  fieldMappings: {
    employees: { name: "full_name", email: "contact.email", targetUtil: "utilization.target" }   // canonical -> dot path on the remote record
  }
}
```

- Response must be a JSON array, either at the root or at `responseRoot` (dot path). Anything else is a clear error message, not a crash.
- **Pull:** fetch → extract array → apply field mapping → normalize/validate → **diff preview** (adds / updates with per-field before→after / unchanged) → user applies. Records with unsaved local edits are flagged in the diff and default to *keep local*; remote never silently overwrites them.
- **Push:** compute local-vs-last-pulled-snapshot diff → preview → send. Push is always explicit, never automatic, never on a timer.
- **CORS:** an always-visible note in the API panel: *"Calls are made directly from your browser. The target API must return `Access-Control-Allow-Origin` (and allow your auth header via `Access-Control-Allow-Headers`) or the browser will block the request. There is no proxy — this app has no server component."* A failed fetch must distinguish a probable CORS failure (TypeError with no status) from an HTTP error status in its message.
- Token entry is a password-type field with a "session only, not saved" hint. Reloading the page clears it.

---

## 7. Panels

| Panel | Contents |
|---|---|
| **Overview** | KPI tiles (headcount, active projects, mean utilization, over-allocated count, unstaffed demand FTE, open alerts by severity), a utilization-vs-target scorecard table, and a monthly org-utilization line chart. |
| **Skills Matrix** | Employee table with inline skill levels per skill column, heat coloring 0–5, filters (discipline, level, office, business group, min level in skill X), paginated 100/page, column sort, quick add/edit employee modal. |
| **Projects** | Project table + register/edit modal + nested Demands editor with a per-month allocation grid (fill-across helper: set a value, drag/type a range). Fill % per demand shown inline. |
| **Optimizer** | Pick a project → pick a demand (or "all open") → weight sliders + preset save/load → ranked candidate cards with score, sub-score bars, modifier chips, and Commit / Monitor / Review actions. "Auto-staff project" opens the preview described in §4.5. |
| **Mentorship** | Current pairings table + suggested pairings ranked by `pairScore` with breakdown, create/end pairing, mentor load indicator (x/2). |
| **Timeline** | Gantt-style grid: rows = employees (or projects, toggle), columns = horizon months, cell = committed % with color bands (under / on target / over / critical), hover shows project split. Below it, a context-switch-tax chart (concurrent projects and tax % per month). |
| **Alerts** | Severity-grouped list, filter by severity/rule/employee, "Run live scan" with progress, threshold configuration inline, click-through to the subject record. |
| **Data & Settings** | Import (file picker + mapping UI + preview), Export (xlsx / per-sheet CSV / template), API connector config + pull/push, horizon settings, ctx-tax settings, session-only toggle, Load demo data, Clear all data, About/vendor/CORS notes. |

---

## 8. Task breakdown

Each task is one Coder pass. Do them in order; do not start a task until the previous one runs in a browser.

1. **Shell & theme.** `index.html` skeleton, dark palette CSS variables, top bar, left nav with the 8 panels, panel routing via hash, empty states. CDN tags for Chart.js and SheetJS with a feature-detect banner.
2. **Constants & utils.** `ROE.const` (enums, adjacency, defaults, schema version) and `ROE.util` (month key math, clamp, id gen, deep equal, fuzzy header match). Pure.
3. **Model & validation.** `ROE.model` record factories + `validate<Entity>(rec)` returning `{ok, errors:[{field,message}]}`. Pure.
4. **Store & IndexedDB.** `ROE.db` open/migrate/read/write; `ROE.store` state, mutations, dirty flag, debounced save, subscribe. Session-only toggle honored here. Clear-all implemented here.
5. **Demo seed data.** ~40 employees, 12 projects with demands, ~120 assignments, 6 mentorships. Original names and project titles — do not copy the reference's records. Realistic distributions (a few over-allocated, a few benched, at least one unstaffed high-priority demand, at least one skill gap) so every alert rule fires at least once.
6. **Calc engine.** `ROE.calc`: index builders, `ctxTax`, `effectiveCapacity`, `committed`, `netCap`, `free`, `utilization`, `demandFill`. Memoized on the store's dirty flag. Pure.
7. **Skills Matrix panel.** Table, filters, sort, pagination, employee add/edit modal, skill level editing.
8. **Projects panel.** Table, project modal, demands editor with the per-month allocation grid and fill-across helper.
9. **Timeline panel.** Gantt grid (employee/project toggle), color bands, hover detail, ctx-tax Chart.js chart.
10. **Scoring engine.** `ROE.score`: sub-scores, composite, modifiers, breakdown object, candidate ranking. Pure. Must expose `scoreCandidate(state, empId, demandId, weights) -> {matchScore, subScores, contributions, modifiers, feasibleFraction, reasons[]}`.
11. **Optimizer panel.** Demand picker, weight sliders + normalization + presets, candidate cards with full breakdown, Commit / Monitor / Review.
12. **Auto-staff solver.** `ROE.score.autoStaff(state, projectId, weights)` per §4.5 + the preview/commit UI. Must never over-allocate past effective capacity.
13. **Alerts engine + panel.** `ROE.alerts.scan(state, thresholds)` pure, all 8 rules, plus the panel, threshold editors, and live-scan progress.
14. **Mentorship engine + panel.** `ROE.mentor.suggest(state)` pure, plus the pairings UI and the 2-mentee cap.
15. **Overview panel.** KPI tiles, scorecard, org utilization chart — built last since it consumes everything above.
16. **Workbook I/O.** `ROE.io`: build workbook, parse workbook, template generation, CSV per sheet, `RequiredSkills` encode/decode. Pure functions taking/returning plain arrays; SheetJS calls isolated to two thin adapters.
17. **Import mapping & preview UI.** Header detection, mapping grid, validation report, insert/update/skip preview, apply.
18. **API connector.** `ROE.api` config UI, session token handling, pull + field map + diff preview, explicit push, CORS note and error classification.
19. **Perf pass.** Generate 1,000 / 200 / 5,000 synthetic records in a dev helper, profile, add pagination limits and index memoization where needed. Target: any panel switch < 400ms, full alert scan < 2s.
20. **Polish & a11y.** Labels on every control, focus rings, tab order, `aria-live` on toasts, keyboard-dismissable modals, About panel with vendor/CDN/CORS/no-backend notes.

---

## 9. Acceptance criteria

### Global
- [ ] `index.html` opened directly from disk (`file://`) boots to a usable empty state with no console errors.
- [ ] No `fetch`/XHR happens at boot other than the two CDN script tags.
- [ ] Blocking the CDNs leaves the app usable: charts and import/export are disabled with a visible explanation, no uncaught exception.
- [ ] Grepping the file finds no PayPal, license-gate, tier-banner, or paywall code.

### Persistence (Task 4)
- [ ] Data survives a page reload.
- [ ] Session-only mode ON → reload loses everything and the badge was visible the whole time.
- [ ] "Clear all data" requires typing `CLEAR`, then leaves every object store empty.
- [ ] After entering an API token, `JSON.stringify` of everything in IndexedDB contains no substring of that token.

### Calc engine (Task 6)
- [ ] `ctxTax(1) = 0`, `ctxTax(2) = 7`, `ctxTax(5) = 28`, `ctxTax(9) = 30` at defaults.
- [ ] An employee at `targetUtil 85` on 3 projects has `effectiveCapacity = 85 * 0.86 = 73.1`.
- [ ] `free()` is never negative; `netCap()` may be.
- [ ] Recomputation over 5,000 assignments × 12 months completes in < 500ms.

### Optimizer (Tasks 10–12)
- [ ] Same state + same weights → identical ranking, run 100 times.
- [ ] Every candidate exposes four sub-scores whose weighted sum plus modifiers equals the displayed `matchScore` (±1 from rounding).
- [ ] An employee with zero free capacity across all demand months scores `availability = 0` and never appears above a candidate with capacity at equal skill.
- [ ] Weight sliders visibly reorder the list; a saved preset restores the exact weights after reload.
- [ ] `requireMinSkillLevels = true` excludes below-minimum candidates and shows the exclusion reason.
- [ ] Auto-staff never produces an assignment that pushes any employee-month above `effectiveCapacity`.
- [ ] Auto-staff on a project with no feasible candidates yields zero assignments and an explicit unfilled reason per demand.
- [ ] Nothing is written to the store until "Commit" is pressed.

### Alerts (Task 13)
- [ ] Demo data fires at least one alert from each of the 8 rules.
- [ ] Raising `overallocPct` from 100 to 130 reduces `SUSTAINED_OVERALLOC` count.
- [ ] Burnout score matches the §4.6 formula on a hand-computed fixture.
- [ ] Alerts are derived, never persisted: clearing IndexedDB and re-importing the same workbook reproduces an identical alert set.

### Mentorship (Task 14)
- [ ] A mentor with 2 active mentees never appears in suggestions.
- [ ] Suggestions are ordered by `pairScore` desc; none below 35 are shown.
- [ ] `compat` label matches the band boundaries exactly at 75 and 50.

### Import/Export (Tasks 16–17)
- [ ] **Round trip:** export → clear all → import the exported file → canonical state deep-equals the original (excluding `updatedAt` and `ExportedAt`).
- [ ] A workbook with renamed headers imports correctly once mapped, and the mapping persists for the session.
- [ ] A row with an invalid enum value is reported with sheet, row number, and field, and does not abort the rest of the import.
- [ ] Import never deletes records absent from the file.
- [ ] Downloaded template imports cleanly as a no-op (all `EXAMPLE-` rows skipped).
- [ ] Month columns outside the horizon are reported and skipped, not silently lost.

### API (Task 18)
- [ ] Config (minus token) survives reload; the token does not.
- [ ] A pull against a mock endpoint maps fields per the mapping UI and shows an add/update diff before applying.
- [ ] Cancelling the diff changes nothing.
- [ ] A record with local unsaved edits defaults to *keep local* in the diff.
- [ ] A CORS-blocked request produces a clear message naming CORS, not a generic failure.
- [ ] Push only fires on an explicit button press, after a preview.

### Performance & a11y (Tasks 19–20)
- [ ] 1,000 employees / 200 projects / 5,000 assignments: every panel renders in < 400ms, alert scan < 2s, no scroll jank.
- [ ] Every panel is reachable and every primary action is operable by keyboard alone.
- [ ] Every input has an associated `<label>` or `aria-label`.

---

## 10. Testing strategy

There is no build step, so the test harness lives beside the artifact and never becomes a runtime dependency.

- **Pure-function contract.** Blocks 1–8 (`const`, `util`, `model`, `calc`, `score`, `alerts`, `mentor`, `io`) touch no DOM and no I/O. They are reachable as `window.ROE.*`. The Coder must keep them that way; any DOM reference in those blocks is a defect.
- **Harness.** A `tests/` directory with a dev-only `package.json` and Playwright. It loads `index.html` from `file://`, then drives two layers:
  1. **Unit-ish:** `page.evaluate()` calls into `ROE.calc`, `ROE.score`, `ROE.alerts`, `ROE.mentor`, `ROE.io` with fixture state, asserting the numeric criteria in §9.
  2. **Functional:** real UI flows — load demo data, run the optimizer, commit a candidate, export, clear, re-import, assert round-trip; run auto-staff and assert no over-allocation; toggle session-only and reload.
- **Mock API.** Playwright `page.route()` intercepts the connector's requests to serve fixture JSON, a 401, and a simulated CORS failure.
- The Tester stage owns writing these and produces `TEST_REPORT.md` ranked CRITICAL → LOW against §9.

---

## 11. Assumptions & defaults recorded

Every one of these is a decision already made. The Coder implements them as written and does not re-litigate.

**Packaging**
1. Single self-contained `index.html`. No build step, no bundler, no Node at runtime. All HTML/CSS/JS inlined.
2. Chart.js and SheetJS loaded from CDN `<script>` tags (matching the reference). Consequence: offline first-load fails for those two features only; feature-detect and degrade gracefully.
3. Assume it may be opened from disk or served from any static host at any path. No absolute paths, no base-path assumptions, no service worker.

**Persistence & privacy**
4. IndexedDB is the store. Session-only mode toggle available. "Clear all data" visible and two-step confirmed.
5. API tokens are in-memory for the session only. Never in IndexedDB, localStorage, sessionStorage, or exports.
6. Single user, browser-only. The API connector is the only sharing mechanism. No multi-user, no auth, no server.

**API**
7. Direct browser calls only. No proxy script, ever. The CORS requirement is documented in-app.
8. Config = base URL + auth + per-entity path + JSON array response + field-mapping UI.
9. Auth modes: API key header, Bearer, none. No OAuth2.
10. Pull + explicit push with preview diff. Remote never auto-overwrites unsaved local edits.

**Domain model**
11. Allocations are time-phased per month (`YYYY-MM` → %), not flat pct + date range. This deliberately upgrades the reference's `startMo`/`endMo` model.
12. Skill levels: canonical storage is **integer 0–5**; names are display-only labels derived from a fixed map. One stored representation, not two.
13. Projects define demand rows: discipline + minimum level + required skills with minimums + openings + per-month FTE %. Demands are the optimizer's unit of work.
14. Optimizer factors: skill match, availability, seniority fit, discipline match. Weights tunable via sliders with savable presets. **Cost and location are out of scope for v1.**
15. Optimizer output: ranked recommendations + one-click commit per candidate + "auto-staff project" respecting capacity ceilings.
16. Scoring is fully deterministic local weighted math. No LLM, no network. Every score shows its factor breakdown.
17. Burnout detection is a multi-factor signal (sustained over-threshold periods + concurrent project count), configurable thresholds. **PTO/leave is skipped — no data source.**

**Scope**
18. All reference panels are in for v1 **except Platform/License Usage**, which is v2 (orthogonal to core staffing).
19. Mentorship pairing = skill gap + seniority delta + discipline + mentor spare capacity, max 2 mentees per mentor.

**Scale, UX, testing**
20. Design point: 1,000 employees / 200 projects / 5,000 assignments. No virtualization — pagination plus memoized indexes instead.
21. Evergreen browsers. Keyboard navigable and labeled. No formal WCAG audit.
22. **Dark theme**, in the spirit of the reference's palette. Chosen because no objection was raised; this is an internal tool where function outranks aesthetics.
23. Testing: core logic structured as extractable pure functions; Tester runs Playwright against the real `index.html` headlessly. `tests/` is dev-only and does not affect the runtime artifact.

**Data**
24. Canonical schema + column-mapping UI + downloadable CSV/XLSX templates (generated in-browser).
25. Single multi-sheet workbook. Lossless round-trip is an acceptance criterion.
26. Ships with loadable demo/seed data — realistic in spirit, **written fresh**, not copied from the reference's names or records. One-click clearable.

**Reference boundary**
27. Reuse the reference's data *shape* and panel *functionality* only. Do not replicate its free-tier banner, license gate modal, PayPal button, or any monetization mechanic. Do not copy its verbatim record data or its layout.

---

## 12. Risks & open questions

**Risks**

| Risk | Impact | Mitigation |
|---|---|---|
| CDN outage or corporate CSP blocks Chart.js/SheetJS | Charts and import/export dead | Feature-detect at boot, degrade with an inline banner, offer a documented path to inline the libraries later if it becomes a real problem |
| Single-file size grows past ~500KB and becomes hard to edit | Coder velocity drops, merge pain | Strict script-block boundaries (§2.2); if the file exceeds ~6,000 lines, flag it to the Manager rather than silently splitting the artifact |
| Greedy auto-staff produces globally suboptimal assignments | User distrust | It is explicitly greedy and previewed, never auto-committed; every pick shows its reasoning and can be rejected individually |
| IndexedDB unavailable (private mode, some `file://` configurations) | No persistence | Detect on boot, auto-fall back to session-only mode with a visible banner rather than failing |
| `file://` origin restrictions break `fetch` to the API | Connector unusable from disk | Document that the API connector requires serving over http(s); show a hint when `location.protocol === 'file:'` |
| Per-month allocation grids are tedious for 12–36 months | Data entry pain | Fill-across helper in the demand and assignment editors (set a value across a month range in one action) |

**Open questions — flagged, not guessed**

1. **Horizon rollover.** What happens when the plan year ends — do we shift the horizon and archive past months, or keep growing it? v1 assumes a fixed, manually-configured horizon with no archiving. Confirm before v2.
2. **Assignment vs. demand drift.** If a demand's monthly % is edited after assignments are committed against it, v1 leaves the assignments untouched and raises an `UNSTAFFED_DEMAND` alert. An alternative is prompting to re-balance. Confirm the v1 behavior is acceptable.
3. **Multi-discipline employees.** The model gives each employee one primary discipline; skills carry the nuance. If people genuinely split across disciplines, the discipline sub-score will misfire. Flagged; not solved in v1.
4. **Push conflict resolution.** v1 pushes a diff against the last-pulled snapshot with no server-side ETag/version check. If the remote changed since the pull, v1 will overwrite it. Acceptable for a single-user internal tool; revisit if the API supports optimistic concurrency.
5. **Budget field.** Carried as an informational KPI only; it feeds no scoring and no cost logic (cost is explicitly out of v1). Confirm no one expects budget-aware staffing.

---

**Status: complete. Hand off to the Coder, starting at Task 1.**
