// Ports the Manager's MGR-A..G probes (MANAGER_REVIEW.md, ADDENDUM 1 REVIEW section) into the
// committed suite. Those probes only ever existed in the Manager's own scratchpad
// (/tmp/.../scratchpad/mgr/specs/mgr-probe.spec.js) - this file makes them permanent so the fix
// round-2 hybrid header-verified matching (index.html readCustom/detectMapping) cannot silently
// regress.
//
// Fix round 2 root cause (see MANAGER_REVIEW.md issues 1-3): the fix-round-1 rewrite matched custom
// columns purely by POSITION (zip leftover columns against the file's own CustomFieldDefs rows, in
// order) with no check that the header text at that position actually matches the def it's being
// paired with. Any structural edit to an exported file (inserting/removing a column, reordering the
// CustomFieldDefs sheet's rows) silently misassigned values with zero reported errors. Fix round 2
// verifies the header text at each position and refuses to guess on mismatch, reporting a clear
// error and leaving the existing stored value untouched instead.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("MGR-A: inserting an extra column in an exported file no longer silently misassigns values", () => {
  test("a hand-added scratch column before the custom column produces a clear error and leaves the existing stored custom value untouched, not corrupted", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Region", "text");
      const def = STORE.getState().customFieldDefs[0];
      const emp = M.newEmployee({ name: "Alice Existing", custom: { [def.key]: "West" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const header = sheets.Employees[0].slice();
      const regionIdx = header.indexOf("Region");
      // Simulate a user inserting a hand-added "Reviewed By" column in Excel, BEFORE the custom
      // "Region" column, shifting every subsequent column by one.
      const editedHeader = header.slice(0, regionIdx).concat(["Reviewed By"]).concat(header.slice(regionIdx));
      const editedRows = sheets.Employees.slice(1).map((row) => row.slice(0, regionIdx).concat(["Bob Reviewer"]).concat(row.slice(regionIdx)));
      const editedAoa = [editedHeader].concat(editedRows);

      const parsed = IO.parseWorkbook(
        { Employees: editedAoa, CustomFieldDefs: sheets.CustomFieldDefs },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      // Mirror applyImport() exactly.
      if (parsed.fieldDefs && parsed.fieldDefs.toAdd.length) STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      STORE.upsert("employees", empRow);
      const after = STORE.getState().employees.find((e) => e.id === emp.id);

      return {
        key: def.key,
        errors: parsed.bySheet.Employees.errors,
        parsedCustom: empRow.custom,
        storedCustomAfterReimport: after.custom,
      };
    });
    console.log("MGR-A result:", JSON.stringify(result));
    // A clear error must be reported naming the affected field, not silence.
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors.some((e) => e.field === "Region")).toBe(true);
    // The wrong value ("Bob Reviewer") must never be assigned to the region key.
    expect(result.parsedCustom ? result.parsedCustom[result.key] : undefined).not.toBe("Bob Reviewer");
    // The existing stored value must survive untouched - not overwritten, not cleared.
    expect(result.storedCustomAfterReimport[result.key]).toBe("West");
  });
});

test.describe("MGR-D: reordering CustomFieldDefs sheet rows no longer swaps values between fields", () => {
  test("swapping the order of two def rows (without touching the entity sheet's column order) is caught as a mismatch instead of silently swapping the two fields' values", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Team", "text");
      STORE.addFieldDef("Employee", "Region", "text");
      const defs = STORE.getState().customFieldDefs;
      const teamDef = defs.find((d) => d.label === "Team");
      const regionDef = defs.find((d) => d.label === "Region");
      const emp = M.newEmployee({ name: "Team Region Person", custom: { [teamDef.key]: "EAST", [regionDef.key]: "ALPHA" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      // Reorder the CustomFieldDefs sheet's data rows (header row stays first), leaving the
      // Employees sheet's column order completely untouched - this is the MGR-D scenario.
      const cfdHeader = sheets.CustomFieldDefs[0];
      const cfdRows = sheets.CustomFieldDefs.slice(1).slice().reverse();
      const reorderedCfd = [cfdHeader].concat(cfdRows);

      const parsed = IO.parseWorkbook(
        { Employees: sheets.Employees, CustomFieldDefs: reorderedCfd },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      if (parsed.fieldDefs && parsed.fieldDefs.toAdd.length) STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      STORE.upsert("employees", empRow);
      const after = STORE.getState().employees.find((e) => e.id === emp.id);

      return {
        teamKey: teamDef.key, regionKey: regionDef.key,
        errors: parsed.bySheet.Employees.errors,
        parsedCustom: empRow.custom,
        storedCustomAfterReimport: after.custom,
      };
    });
    console.log("MGR-D result:", JSON.stringify(result));
    expect(result.errors.length).toBeGreaterThan(0);
    // Values must never swap: team must never end up holding "ALPHA", region must never hold "EAST".
    expect(result.parsedCustom ? result.parsedCustom[result.teamKey] : undefined).not.toBe("ALPHA");
    expect(result.parsedCustom ? result.parsedCustom[result.regionKey] : undefined).not.toBe("EAST");
    // Existing stored values survive untouched rather than being silently swapped.
    expect(result.storedCustomAfterReimport[result.teamKey]).toBe("EAST");
    expect(result.storedCustomAfterReimport[result.regionKey]).toBe("ALPHA");
  });
});

test.describe("MGR-E: deleting a canonical column no longer lets fuzzy matching steal a custom column", () => {
  test("removing the canonical Office column while a custom field labelled 'Office Location' exists leaves Office unmapped and the custom value intact, instead of the fuzzy matcher stealing the custom column for Office", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Office Location", "text");
      const def = STORE.getState().customFieldDefs[0];
      const emp = M.newEmployee({ name: "Office Person", office: "HQ-Original", custom: { [def.key]: "Denver" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const header = sheets.Employees[0];
      const officeIdx = header.indexOf("Office");
      // Simulate a user deleting the canonical "Office" column entirely in Excel.
      const editedHeader = header.slice(0, officeIdx).concat(header.slice(officeIdx + 1));
      const editedRows = sheets.Employees.slice(1).map((row) => row.slice(0, officeIdx).concat(row.slice(officeIdx + 1)));
      const editedAoa = [editedHeader].concat(editedRows);

      const parsed = IO.parseWorkbook(
        { Employees: editedAoa, CustomFieldDefs: sheets.CustomFieldDefs },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);

      return {
        key: def.key,
        officeAfterReparse: empRow.office,
        customAfterReparse: empRow.custom,
      };
    });
    console.log("MGR-E result:", JSON.stringify(result));
    // The custom "Office Location" value must never be stolen into the canonical Office field.
    expect(result.officeAfterReparse).not.toBe("Denver");
    // The custom field itself must still correctly round-trip its own value.
    expect(result.customAfterReparse[result.key]).toBe("Denver");
  });
});

test.describe("MGR-C: an invalid Number-field cell value produces a validation error WITHOUT erasing the existing stored value", () => {
  test("a non-numeric cell ('N/A') in a Number custom column is reported as an error and the previously stored numeric value for that key survives re-import untouched", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Badge", "number");
      const def = STORE.getState().customFieldDefs[0];
      const emp = M.newEmployee({ name: "Badge Person", custom: { [def.key]: 42 } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const header = sheets.Employees[0];
      const badgeIdx = header.indexOf("Badge");
      const editedRows = sheets.Employees.slice(1).map((row) => {
        const copy = row.slice();
        copy[badgeIdx] = "N/A";
        return copy;
      });
      const editedAoa = [header].concat(editedRows);

      const parsed = IO.parseWorkbook(
        { Employees: editedAoa, CustomFieldDefs: sheets.CustomFieldDefs },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      if (parsed.fieldDefs && parsed.fieldDefs.toAdd.length) STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      STORE.upsert("employees", empRow);
      const after = STORE.getState().employees.find((e) => e.id === emp.id);

      return {
        key: def.key,
        errors: parsed.bySheet.Employees.errors,
        recordStillImported: !!empRow,
        storedCustomAfterReimport: after.custom,
      };
    });
    console.log("MGR-C result:", JSON.stringify(result));
    expect(result.errors.some((e) => e.field === "Badge" && /must be a number/.test(e.message))).toBe(true);
    expect(result.recordStillImported).toBe(true);
    // The existing stored badge=42 must survive - not wiped by the invalid cell.
    expect(result.storedCustomAfterReimport[result.key]).toBe(42);
  });
});

test.describe("MGR-B: a rejected CustomFieldDefs row doesn't cascade into misassigning subsequent fields", () => {
  test("a def row missing its Key is rejected (and excluded from matching) while the surviving def's column is caught as a header mismatch instead of silently absorbing the wrong column's value", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Team", "text");
      STORE.addFieldDef("Employee", "Badge", "number");
      const defs = STORE.getState().customFieldDefs;
      const teamDef = defs.find((d) => d.label === "Team");
      const badgeDef = defs.find((d) => d.label === "Badge");
      const emp = M.newEmployee({ name: "Team Badge Person", custom: { [teamDef.key]: "EAST", [badgeDef.key]: 42 } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      // Hand-edit the CustomFieldDefs sheet: blank out the "Team" row's Key cell (column index 1),
      // simulating a rejected row, WITHOUT removing its column from the Employees sheet.
      const cfdHeader = sheets.CustomFieldDefs[0];
      const keyIdx = cfdHeader.indexOf("Key");
      const editedCfdRows = sheets.CustomFieldDefs.slice(1).map((row) => {
        if (row[cfdHeader.indexOf("Label")] === "Team") {
          const copy = row.slice();
          copy[keyIdx] = "";
          return copy;
        }
        return row;
      });
      const editedCfd = [cfdHeader].concat(editedCfdRows);

      const parsed = IO.parseWorkbook(
        { Employees: sheets.Employees, CustomFieldDefs: editedCfd },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      if (parsed.fieldDefs && parsed.fieldDefs.toAdd.length) STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      STORE.upsert("employees", empRow);
      const after = STORE.getState().employees.find((e) => e.id === emp.id);

      return {
        teamKey: teamDef.key, badgeKey: badgeDef.key,
        fieldDefErrors: parsed.fieldDefs.errors,
        employeeErrors: parsed.bySheet.Employees.errors,
        parsedCustom: empRow.custom,
        storedCustomAfterReimport: after.custom,
      };
    });
    console.log("MGR-B result:", JSON.stringify(result));
    // The malformed CustomFieldDefs row itself is correctly rejected.
    expect(result.fieldDefErrors.some((e) => e.message === "EntityType and Key are required")).toBe(true);
    // The surviving "Badge" def must never silently absorb the "Team" column's text value.
    expect(result.parsedCustom ? result.parsedCustom[result.badgeKey] : undefined).not.toBe("EAST");
    // Existing stored values for both keys survive untouched.
    expect(result.storedCustomAfterReimport[result.teamKey]).toBe("EAST");
    expect(result.storedCustomAfterReimport[result.badgeKey]).toBe(42);
  });
});

test.describe("MGR-F (control): two custom defs sharing an identical label round-trip losslessly on an app-generated, unedited file", () => {
  test("app-generated export/import of two same-labelled Employee custom fields never regresses", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Region", "text");
      STORE.addFieldDef("Employee", "Region", "number");
      const defs = STORE.getState().customFieldDefs;
      const keyA = defs[0].key, keyB = defs[1].key;
      const emp = M.newEmployee({ name: "Dual Region", custom: { [keyA]: "East", [keyB]: 7 } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const parsed = IO.parseWorkbook(sheets, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      const reparsed = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      return { keys: [keyA, keyB], custom: reparsed.custom, errors: parsed.bySheet.Employees.errors, headers: sheets.Employees[0] };
    });
    console.log("MGR-F result:", JSON.stringify(result));
    expect(result.headers.filter((h) => h === "Region").length).toBe(2);
    expect(result.errors.length).toBe(0);
    expect(result.custom[result.keys[0]]).toBe("East");
    expect(result.custom[result.keys[1]]).toBe(7);
  });
});

test.describe("MGR-G (control): a wide-month sheet re-imported into a non-overlapping horizon still doesn't shift the custom column", () => {
  test("month columns are always claimed by isMonthKey regardless of horizon overlap, so the custom column position is never disturbed", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Demand", "Cost Code", "text");
      const def = STORE.getState().customFieldDefs[0];
      const project = M.newProject({ name: "P" });
      STORE.upsert("projects", project);
      const demand = M.newDemand({ projectId: project.id, title: "D", custom: { [def.key]: "CC-1" } });
      STORE.upsert("demands", demand);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      // Re-import against a state whose horizon no longer overlaps the file's month columns at all.
      const shiftedSettings = Object.assign({}, STORE.getState().settings, { horizonStart: "2031-01", horizonMonths: 3 });
      const parsed = IO.parseWorkbook(
        { ProjectDemands: sheets.ProjectDemands, CustomFieldDefs: sheets.CustomFieldDefs },
        shiftedSettings, null, STORE.getState().customFieldDefs
      );
      const reparsed = parsed.bySheet.ProjectDemands.records.find((r) => r.id === demand.id);
      return { key: def.key, custom: reparsed ? reparsed.custom : null, monthWarnCount: parsed.monthWarnings.reduce((n, w) => n + w.headers.length, 0), errors: parsed.bySheet.ProjectDemands.errors };
    });
    console.log("MGR-G result:", JSON.stringify(result));
    expect(result.monthWarnCount).toBeGreaterThan(0);
    expect(result.errors.length).toBe(0);
    expect(result.custom[result.key]).toBe("CC-1");
  });
});
