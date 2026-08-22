// FINAL RE-TEST ROUND — independent re-verification of the Coder's claimed fix for the 4 findings
// in TEST_REPORT.md's ADDENDUM 1 section (commit 3452c8d, position-based custom-column matching +
// __importedCustomKeys merge-not-replace + "Unknown skill" fallback rendering).
//
// Written FRESH, not copy-pasted from adversarial-custom-fields-addendum.spec.js, to avoid trusting
// my own prior test's framing. Also probes one new angle: a CustomFieldDefs sheet entry for an
// entity type this app's constant list does not recognize at all, and (separately) a def for a
// key genuinely never seen locally before (IO-1's "recreate any defs missing locally" bullet).
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("RE-TEST: repro #1 (CRITICAL) — re-import must not erase existing custom values absent from the file", () => {
  test("two custom fields, only ONE present as a column in the re-imported file: the present one updates/clears per-cell, the absent one is left completely untouched", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      STORE.addFieldDef("Employee", "Badge Number", "number");
      STORE.addFieldDef("Employee", "Home Office", "text");
      const defs = STORE.getState().customFieldDefs;
      const badgeKey = defs.find((d) => d.label === "Badge Number").key;
      const officeKey = defs.find((d) => d.label === "Home Office").key;

      const emp = STORE.getState().employees[0];
      emp.custom = {};
      emp.custom[badgeKey] = 42;
      emp.custom[officeKey] = "Denver";
      STORE.upsert("employees", emp);
      const empId = emp.id;

      // Build a hand-crafted re-import file that ONLY has a "Badge Number" column (simulating a
      // partial/older export that never knew about "Home Office"), and gives it a NEW value.
      // A genuinely self-consistent "older export" file: its OWN CustomFieldDefs sheet only
      // knows about Badge Number (simulating a file taken after Badge Number existed but before
      // Home Office was ever added) - Home Office has NO row in CustomFieldDefs and NO column here.
      const cfdAoa = [
        ["EntityType", "Key", "Label", "Type"],
        ["Employee", badgeKey, "Badge Number", "number"],
      ];
      const aoa = [
        ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes", "Badge Number"],
        [empId, emp.name, emp.email, emp.level, emp.discipline, emp.office, emp.businessGroup, emp.targetUtil, emp.mentorRole, emp.active, emp.notes, 777],
      ];
      const parsed = IO.parseWorkbook({ CustomFieldDefs: cfdAoa, Employees: aoa }, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      if (parsed.fieldDefs && parsed.fieldDefs.toAdd.length) STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      parsed.bySheet.Employees.records.forEach((rec) => STORE.upsert("employees", rec));

      const after = STORE.getState().employees.find((e) => e.id === empId);
      return { badgeKey, officeKey, customAfter: after.custom };
    });
    console.log("repro#1 fresh result:", JSON.stringify(result));
    // Badge Number WAS present in the file -> updates to the new value.
    expect(result.customAfter[result.badgeKey]).toBe(777);
    // Home Office had NO column in the file at all -> must survive untouched, not vanish.
    expect(result.customAfter[result.officeKey]).toBe("Denver");
  });

  test("a column that IS present but the cell is blank is an explicit clear, not 'leave alone'", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      STORE.addFieldDef("Employee", "Badge Number", "number");
      const key = STORE.getState().customFieldDefs[0].key;
      const emp = STORE.getState().employees[0];
      emp.custom = { [key]: 42 };
      STORE.upsert("employees", emp);
      const empId = emp.id;

      const cfdAoa = [
        ["EntityType", "Key", "Label", "Type"],
        ["Employee", key, "Badge Number", "number"],
      ];
      const aoa = [
        ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes", "Badge Number"],
        [empId, emp.name, emp.email, emp.level, emp.discipline, emp.office, emp.businessGroup, emp.targetUtil, emp.mentorRole, emp.active, emp.notes, ""],
      ];
      const parsed = IO.parseWorkbook({ CustomFieldDefs: cfdAoa, Employees: aoa }, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      parsed.bySheet.Employees.records.forEach((rec) => STORE.upsert("employees", rec));
      const after = STORE.getState().employees.find((e) => e.id === empId);
      return { key, customAfter: after.custom };
    });
    console.log("explicit-blank-clear result:", JSON.stringify(result));
    expect(result.customAfter && result.customAfter[result.key]).toBeUndefined();
  });
});

test.describe("RE-TEST: repro #2 (HIGH) — duplicate label round-trip via real Manage Fields UI", () => {
  test("two Employee custom fields both added via the real UI with the identical label 'Territory' round-trip distinct values, not swapped or merged", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#skills"; });
    await page.waitForTimeout(200);

    await page.click("#btn-manage-emp-fields");
    await page.fill("#mf-label", "Territory");
    await page.selectOption("#m-mf-type", "text");
    await page.click("#mf-add");
    await page.waitForTimeout(80);
    await page.fill("#mf-label", "Territory");
    await page.selectOption("#m-mf-type", "text");
    await page.click("#mf-add");
    await page.waitForTimeout(80);
    await page.click("#mf-close");
    await page.waitForTimeout(80);

    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      const defs = STORE.getState().customFieldDefs.filter((d) => d.label === "Territory");
      const keyA = defs[0].key, keyB = defs[1].key;
      const emp = STORE.getState().employees[0];
      emp.custom = Object.assign({}, emp.custom, { [keyA]: "North", [keyB]: "South" });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const parsed = IO.parseWorkbook(sheets, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      const reparsed = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      return { keyA, keyB, north: reparsed.custom[keyA], south: reparsed.custom[keyB] };
    });
    console.log("repro#2 fresh (real UI) result:", JSON.stringify(result));
    expect(result.north).toBe("North");
    expect(result.south).toBe("South");
  });
});

test.describe("RE-TEST: repro #3 (HIGH) — custom label colliding with a canonical column name stays distinct on round-trip", () => {
  test("a custom field literally labeled 'Notes' (Number type, colliding with the canonical free-text Notes column) round-trips its OWN numeric value with no cross-contamination and no spurious validation error", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      STORE.addFieldDef("Employee", "Notes", "number");
      const key = STORE.getState().customFieldDefs[0].key;
      const emp = STORE.getState().employees[0];
      emp.notes = "This is free-text canonical notes, not a number";
      emp.custom = { [key]: 12345 };
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const parsed = IO.parseWorkbook(sheets, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      const reparsed = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      const errorsForThisRow = parsed.bySheet.Employees.errors;
      return {
        key,
        canonicalNotesAfter: reparsed.notes,
        customValueAfter: reparsed.custom ? reparsed.custom[key] : undefined,
        errorCount: errorsForThisRow.length,
        errors: errorsForThisRow,
      };
    });
    console.log("repro#3 fresh result:", JSON.stringify(result));
    expect(result.canonicalNotesAfter).toBe("This is free-text canonical notes, not a number");
    expect(result.customValueAfter).toBe(12345);
    expect(result.errorCount).toBe(0);
  });
});

test.describe("RE-TEST: repro #4 (MEDIUM) — 'Unknown skill' rendering for a Demand's requiredSkills, not just EmployeeSkill", () => {
  test("deleting a Skill referenced by a Demand.requiredSkills entry renders 'Unknown skill (ID)' in that demand's editor, not just a bare dangling ID", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);

    const setup = await page.evaluate(() => {
      const STORE = window.ROE.store;
      const s = STORE.getState();
      const skill = s.skills[0];
      const demand = s.demands.find((d) => d.projectId) || s.demands[0];
      demand.requiredSkills = [{ skillId: skill.id, minLevel: 3, weight: 2 }];
      STORE.upsert("demands", demand);
      return { skillId: skill.id, projectId: demand.projectId, demandId: demand.id };
    });

    // Sanity: before deletion, resolved label shows the real skill name, not "Unknown skill".
    await page.evaluate(() => { location.hash = "#projects"; });
    await page.waitForTimeout(200);
    await page.click(`.edit-prj[data-id="${setup.projectId}"]`);
    await page.waitForTimeout(150);
    let bodyText = await page.evaluate(() => document.body.innerText);
    expect(bodyText).not.toContain("Unknown skill");
    await page.click("#m-cancel").catch(() => {});
    await page.waitForTimeout(100);

    // Delete the referenced skill.
    page.once("dialog", (d) => d.accept());
    await page.evaluate(() => { location.hash = "#skills"; });
    await page.waitForTimeout(200);
    await page.click(`.delete-skill[data-id="${setup.skillId}"]`);
    await page.waitForTimeout(200);

    // Reopen the SAME project's demand editor and look for the resolved fallback label.
    await page.evaluate(() => { location.hash = "#projects"; });
    await page.waitForTimeout(200);
    await page.click(`.edit-prj[data-id="${setup.projectId}"]`);
    await page.waitForTimeout(200);
    bodyText = await page.evaluate(() => document.body.innerText);
    console.log("demand editor text contains 'Unknown skill':", bodyText.includes("Unknown skill"));
    console.log("demand editor text contains the dangling skill id:", bodyText.includes(setup.skillId));
    expect(bodyText).toContain("Unknown skill");
    expect(bodyText).toContain(setup.skillId);

    // Confirm no crash and the requiredSkills data itself was never mutated/dropped.
    const stillIntact = await page.evaluate((did) => {
      const d = window.ROE.store.getState().demands.find((x) => x.id === did);
      return d.requiredSkills.length;
    }, setup.demandId);
    expect(stillIntact).toBe(1);
  });
});

test.describe("NEW ADVERSARIAL PASS: CustomFieldDefs sheet edge cases beyond the original 4 findings", () => {
  test("a CustomFieldDefs row for a def genuinely unseen locally (never added in this session) is cleanly recreated on import, and its value round-trips into record.custom", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      const localDefsBefore = STORE.getState().customFieldDefs.length;
      const emp = STORE.getState().employees[0];

      // Hand-built file: CustomFieldDefs sheet defines a field this local instance has NEVER seen
      // (simulating a colleague's export, or a much older/different-session file), plus a matching
      // data column on the Employees sheet.
      const sheetsAoA = {
        CustomFieldDefs: [
          ["EntityType", "Key", "Label", "Type"],
          ["Employee", "cost_center", "Cost Center", "text"],
        ],
        Employees: [
          ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes", "Cost Center"],
          [emp.id, emp.name, emp.email, emp.level, emp.discipline, emp.office, emp.businessGroup, emp.targetUtil, emp.mentorRole, emp.active, emp.notes, "CC-9001"],
        ],
      };
      const parsed = IO.parseWorkbook(sheetsAoA, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      const toAddKeys = parsed.fieldDefs.toAdd.map((d) => d.key);
      STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      parsed.bySheet.Employees.records.forEach((rec) => STORE.upsert("employees", rec));

      const localDefsAfter = STORE.getState().customFieldDefs;
      const after = STORE.getState().employees.find((e) => e.id === emp.id);
      return {
        localDefsBefore,
        toAddKeys,
        recreatedDef: localDefsAfter.find((d) => d.key === "cost_center"),
        customValueAfter: after.custom ? after.custom["cost_center"] : undefined,
      };
    });
    console.log("unseen-def recreate result:", JSON.stringify(result));
    expect(result.toAddKeys).toContain("cost_center");
    expect(result.recreatedDef).toBeTruthy();
    expect(result.recreatedDef.entityType).toBe("Employee");
    expect(result.recreatedDef.label).toBe("Cost Center");
    expect(result.customValueAfter).toBe("CC-9001");
  });

  test("a CustomFieldDefs row for an entity type NOT among this app's recognized 6 types (hand-edited/foreign file) is rejected as a per-row error, never crashes, never silently invents a def, and does not block the rest of the import", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const jsErrors = [];
    page.on("pageerror", (e) => jsErrors.push(String(e)));

    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      const emp = STORE.getState().employees[0];
      const sheetsAoA = {
        CustomFieldDefs: [
          ["EntityType", "Key", "Label", "Type"],
          ["Vendor", "vendor_field", "Vendor Field", "text"], // "Vendor" is not a recognized entity type
          ["Employee", "legit_field", "Legit Field", "text"], // a valid row in the SAME sheet, right after the bad one
        ],
        Employees: [
          ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes", "Legit Field"],
          [emp.id, emp.name, emp.email, emp.level, emp.discipline, emp.office, emp.businessGroup, emp.targetUtil, emp.mentorRole, emp.active, emp.notes, "OK"],
        ],
      };
      const parsed = IO.parseWorkbook(sheetsAoA, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      parsed.bySheet.Employees.records.forEach((rec) => STORE.upsert("employees", rec));
      const after = STORE.getState().employees.find((e) => e.id === emp.id);
      return {
        fieldDefErrors: parsed.fieldDefs.errors,
        toAddKeys: parsed.fieldDefs.toAdd.map((d) => d.key),
        vendorDefCreated: STORE.getState().customFieldDefs.some((d) => d.entityType === "Vendor"),
        legitDefCreated: STORE.getState().customFieldDefs.some((d) => d.key === "legit_field"),
        legitValue: after.custom ? after.custom["legit_field"] : undefined,
      };
    });
    console.log("unsupported-entity-type result:", JSON.stringify(result), "jsErrors:", JSON.stringify(jsErrors));
    expect(jsErrors.length).toBe(0); // must never crash
    expect(result.vendorDefCreated).toBe(false); // never silently invents a def for an unrecognized entity type
    expect(result.fieldDefErrors.length).toBeGreaterThan(0); // the bad row IS reported as an error, not swallowed
    // The valid row in the same sheet must still succeed - one bad CustomFieldDefs row doesn't
    // poison the rest of the sheet or the rest of the import.
    expect(result.legitDefCreated).toBe(true);
    expect(result.legitValue).toBe("OK");
  });

  test("GAP CHECK: does the Import Preview UI actually surface the CustomFieldDefs-sheet-level error TEXT (not just a count) anywhere the user can read it?", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      const ui = window.ROE.ui;
      const sheetsAoA = {
        CustomFieldDefs: [
          ["EntityType", "Key", "Label", "Type"],
          ["Vendor", "vendor_field", "Vendor Field", "text"],
        ],
      };
      // Mirror handleImportFile's real session state so previewImport() renders for real.
      window.__uiStateProbe = true;
      const state = STORE.getState();
      const parsed = IO.parseWorkbook(sheetsAoA, state.settings, null, state.customFieldDefs);
      const summary = IO.diffAgainstState(state, parsed);
      return { fieldDefErrors: parsed.fieldDefs.errors, cfdSummary: summary.CustomFieldDefs };
    });
    console.log("preview-surface check:", JSON.stringify(result));
    // Documenting behavior, not asserting pass/fail destructively: the count IS available...
    expect(result.cfdSummary.errors).toBeGreaterThan(0);
    // ...but previewImport()'s errorList only iterates parsed.bySheet, never parsed.fieldDefs.errors
    // (index.html ~4402), so the actual message text for a CustomFieldDefs-sheet problem is not
    // reachable via that loop. Confirmed by static read, not asserted here to avoid a redundant
    // failing assertion; see write-up.
  });
});
