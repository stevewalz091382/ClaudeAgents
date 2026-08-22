# BUILD PLAN ADDENDUM 1 — Custom fields + full manual CRUD

Supplements `BUILD_PLAN.md` (v1, shipped and GO'd — see `MANAGER_REVIEW.md`). Do not re-litigate v1 decisions; this is additive. User-confirmed scope (asked directly, no re-run of the full architect Q&A given the codebase context is already established):

- Custom fields apply to **all 6 entity types**: Employees, Projects, Project Demands, Assignments, Mentorships, Skills.
- Field types: **Text and Number only** (no dropdown/boolean/date in this pass).
- Assignments and Skills currently have **no manual entry form at all** (only born via optimizer/auto-staff/import/API) — this addendum also builds those forms, since custom fields on a record type presuppose you can create/edit one by hand.
- The "export/import everything to one Excel file" ask is **already built** (`ROE.io.buildWorkbookSheets`/`parseWorkbook`, wired to `#btn-export-xlsx` and `#import-file`, covers all entities in one workbook). This addendum's job for that half of the request is to (a) make sure custom field values/defs round-trip losslessly through it, and (b) get the one still-open item from `MANAGER_REVIEW.md` closed: a real manual, network-enabled verification that the actual file download → re-upload cycle works (not just the pure functions), since the CDN has been blocked in every sandbox this pipeline has run in so far.

---

## 1. Requirements

- [ ] **CF-1** A `CustomFieldDef` per entity type: `{id, entityType, key, label, type: "text"|"number", createdAt}`. `key` is a stable, URL-safe identifier generated from the label at creation (editable only by deleting and recreating — renaming the *label* is fine and does not affect `key` or stored values).
- [ ] **CF-2** A "Manage fields" UI reachable from each entity's panel (Skills Matrix, Projects, Mentorship) and from the new Assignment/Skill panels — add a field (label + type), remove a field (values already stored under that key are left alone in the record, just no longer shown/editable — never silently deleted), reorder is not required.
- [ ] **CF-3** Every manual add/edit form (existing: Employee, Project, Demand, Mentorship; new: Assignment, Skill) renders the current custom field defs for that entity type as extra inputs at the bottom of the form, reading/writing `record.custom[key]`. Number fields validate numeric input; text fields accept any string. Unset custom fields are simply absent from `record.custom`, not stored as empty string/0.
- [ ] **CF-4** `ROE.model` validators accept an optional `custom` object on every entity and validate only the fields that have a matching def of type `number` (must parse as a number if present) — unknown keys are permitted (a def removed elsewhere shouldn't invalidate existing data).
- [ ] **NEW-1** Assignment manual create/edit modal: pick project, employee, optional demand (filtered to that project's open demands), a per-month allocation grid reusing the existing fill-across helper from the Demand editor, status (`Proposed`/`Committed`), and now also custom fields per CF-3. Must respect `effectiveCapacity` the same way the optimizer/auto-staff do — warn (don't silently block) if the manual allocation would push the employee over capacity in any month.
- [ ] **NEW-2** Skill manual create/edit modal: code (unique, uppercase-normalized), name, category, plus custom fields per CF-3. Deleting a skill in use should warn how many `EmployeeSkill`/`RequiredSkills` references exist; deletion proceeds only on confirm and those references are left with a dangling `skillId` (same "never silently delete data" principle as CF-2 — display "Unknown skill" for orphaned references rather than crashing).
- [ ] **IO-1** `CustomFieldDefs` sheet added to the workbook (`entityType | Key | Label | Type`), plus one new column per active custom field appended to each entity's existing sheet (header = the field's `label`, cell = `record.custom[key]`). Import: read `CustomFieldDefs` first, recreate any defs missing locally (never delete a local def not present in the file), then map matching columns on each entity sheet back into `record.custom`.
- [ ] **VERIFY-1** One real, network-enabled manual pass (not a sandboxed Playwright mock) confirming: Chart.js actually renders a chart, SheetJS actually builds a downloadable `.xlsx`, and that file re-imports cleanly. If this pipeline is run somewhere the CDN is still blocked, state that plainly rather than re-asserting the pure-function-only verification as if it were equivalent — this has now been asked for twice.

## 2. Data model additions

```js
CustomFieldDef { id, entityType: "Employee"|"Project"|"Demand"|"Assignment"|"Mentorship"|"Skill", key, label, type: "text"|"number", createdAt }

// every existing entity gains an optional:
record.custom = { [key]: string | number }
```

IndexedDB: add object store `customFieldDefs`. This is a schema version bump (`meta.schemaVersion` 1 → 2) — implement it through the migration ladder already described in BUILD_PLAN.md §2.6 ("if `meta.schemaVersion` mismatches, run the migration ladder"), not a breaking change to existing installs. On migration: create the new store empty; existing records are untouched (they simply have no `custom` key yet, which is valid — CF-4 treats it as absent, not invalid).

## 3. Workbook schema addition

New sheet `CustomFieldDefs`: `EntityType | Key | Label | Type`.

Each entity sheet (`Employees`, `Projects`, `ProjectDemands`, `Assignments`, `Mentorships`, `Skills`) gains one column per def for that entity type, appended after the existing canonical columns, header = `label`. Import must not require these columns to be present (older exports / hand-edited files without them still import cleanly — absence means no custom values, not an error).

## 4. Task breakdown

1. Schema migration: `customFieldDefs` store, `schemaVersion` 2, migration ladder entry, `ROE.model` support for `record.custom` on all 6 types (CF-4).
2. `ROE.const`/`ROE.model`: CRUD helpers for field defs (`addFieldDef`, `removeFieldDef`, `listFieldDefs(entityType)`), key-generation from label, uniqueness check per entity type.
3. "Manage fields" UI component (reusable across the 6 entity panels) + wiring into Skills Matrix, Projects, Mentorship panels.
4. Extend Employee, Project, Demand, Mentorship forms with dynamic custom-field inputs (CF-3).
5. Build the new Assignment manual create/edit modal (NEW-1), including its own "Manage fields" entry point.
6. Build the new Skill manual create/edit modal (NEW-2), including its own "Manage fields" entry point.
7. `ROE.io`: extend `buildWorkbookSheets`/`parseWorkbook` for `CustomFieldDefs` sheet + per-entity custom columns (IO-1). Update the downloadable template generator to include current field defs.
8. Manual verification pass in a real, network-enabled browser (VERIFY-1) — chart rendering, real `.xlsx` export, real re-import.

## 5. Acceptance criteria (additions to BUILD_PLAN.md §9)

- [ ] Adding a custom Number field to Employees, entering a value, exporting, clearing all data, and re-importing reproduces the exact value and the field definition itself (workbook round-trip now covers custom fields, not just canonical ones).
- [ ] Removing a field def does not delete existing values from any record; those records simply stop showing that input until the def is re-added.
- [ ] A record with no custom values at all round-trips with no stray `custom: {}` noise (omit the key rather than storing empty object), and does not break existing (pre-addendum) exported files that have no `CustomFieldDefs` sheet at all.
- [ ] Assignment and Skill can now be created, edited, and deleted entirely by hand, with the same "never silently destroy data" discipline as the rest of the app (confirm dialogs on delete, orphaned references shown rather than crashing).
- [ ] A manually-created Assignment that would push an employee over `effectiveCapacity` in some month is allowed but visibly warned, not silently permitted or silently blocked.
- [ ] Existing IndexedDB data from a v1 install migrates cleanly to schemaVersion 2 with zero data loss (test: seed v1-shaped data, force schemaVersion back to 1, reload, confirm migration runs once and all v1 acceptance criteria from BUILD_PLAN.md §9 still pass).
- [ ] VERIFY-1 is either genuinely done (report what was seen) or genuinely flagged as still blocked by network access — not silently dropped.

---

**Status: complete. Hand off to the Coder.**
