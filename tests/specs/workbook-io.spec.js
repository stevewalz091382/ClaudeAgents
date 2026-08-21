// §9 "Import/Export" acceptance criteria. The CDN for SheetJS is blocked in this sandbox (verified
// via zz-boot / manual curl to the proxy status endpoint - same failure mode the Coder reported),
// so the real file-download/upload cycle through window.XLSX cannot be exercised here. These tests
// exercise ROE.io's pure functions directly (build/parse/diff), which is everything that does not
// require the blocked vendor library, and separately confirm the app degrades correctly when the
// library truly is absent.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("Workbook round-trip & import validation (§9 Import/Export, pure-function level)", () => {
  test("round trip: build -> parse reproduces canonical state (excluding updatedAt/ExportedAt)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, U = window.ROE.util;
      const state = STORE.getState();
      const sheets = IO.buildWorkbookSheets(state);
      const parsed = IO.parseWorkbook(sheets, state.settings, null);

      function stripUpdatedAt(rec) {
        const c = Object.assign({}, rec);
        delete c.updatedAt;
        return c;
      }
      function normSet(arr) {
        return arr.map(stripUpdatedAt).sort((a, b) => (a.id || "").localeCompare(b.id || ""));
      }

      const checks = {};
      checks.employees = U.deepEqual(normSet(parsed.bySheet.Employees.records), normSet(state.employees));
      checks.projects = U.deepEqual(normSet(parsed.bySheet.Projects.records), normSet(state.projects));
      checks.demands = U.deepEqual(normSet(parsed.bySheet.ProjectDemands.records), normSet(state.demands));
      checks.assignments = U.deepEqual(normSet(parsed.bySheet.Assignments.records), normSet(state.assignments));
      checks.mentorships = U.deepEqual(normSet(parsed.bySheet.Mentorships.records), normSet(state.mentorships));
      checks.skills = U.deepEqual(normSet(parsed.bySheet.Skills.records), normSet(state.skills));
      const errorCounts = Object.keys(parsed.bySheet).map((s) => ({ sheet: s, errors: parsed.bySheet[s].errors }));
      return { checks, errorCounts };
    });
    Object.entries(result.checks).forEach(([sheet, ok]) => {
      expect(ok, `round-trip mismatch on sheet "${sheet}"`).toBe(true);
    });
    result.errorCounts.forEach(({ sheet, errors }) => {
      expect(errors, `unexpected validation errors on round-trip for ${sheet}: ${JSON.stringify(errors)}`).toEqual([]);
    });
  });

  test("a row with an invalid enum value is reported with sheet/row/field and does not abort the rest of the import", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const IO = window.ROE.io;
      const settings = { horizonStart: "2026-01", horizonMonths: 3 };
      const aoa = [
        ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes"],
        ["emp_bad", "Bad Enum Person", "x@example.com", "NotALevel", "Civil", "Anywhere", "Transportation", 85, "None", true, ""],
        ["emp_good", "Good Person", "y@example.com", "Senior", "Civil", "Anywhere", "Transportation", 85, "None", true, ""],
      ];
      const r = IO.parseSheet("Employees", aoa, { monthKeys: [] });
      return { errors: r.errors, recordCount: r.records.length, ids: r.records.map((x) => x.id) };
    });
    expect(result.errors.length).toBeGreaterThan(0);
    expect(result.errors[0].sheet).toBeUndefined(); // parseSheet doesn't stamp sheet; parseWorkbook does - check that path too
    expect(result.recordCount).toBe(1); // the good row still gets through
    expect(result.ids).toEqual(["emp_good"]);
  });

  test("parseWorkbook stamps sheet name + row number + field on invalid rows", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const IO = window.ROE.io;
      const settings = { horizonStart: "2026-01", horizonMonths: 3 };
      const sheets = {
        Employees: [
          ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes"],
          ["emp_bad", "Bad Enum Person", "x@example.com", "NotALevel", "Civil", "Anywhere", "Transportation", 85, "None", true, ""],
        ],
      };
      const parsed = IO.parseWorkbook(sheets, settings, null);
      return parsed.bySheet.Employees.errors;
    });
    expect(result.length).toBeGreaterThan(0);
    expect(result[0].sheet).toBe("Employees");
    expect(result[0].row).toBe(2); // header is row 1, first data row is row 2
    expect(typeof result[0].field).toBe("string");
  });

  test("import merge semantics: existing ID updates, new ID inserts, ID absent from the file is left alone (never deleted)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      const state = STORE.getState();
      const before = state.employees.length;
      const untouchedId = state.employees[0].id;
      const updatedExisting = state.employees[1];

      const sheets = IO.buildWorkbookSheets(state);
      // Rebuild the Employees sheet containing only ONE existing (updated) row + ONE brand new row -
      // i.e. everyone else is "absent from the file".
      const header = sheets.Employees[0];
      const updatedRow = sheets.Employees.find((r) => r[0] === updatedExisting.id);
      const newRow = header.map((h) => (h === "EmployeeID" ? "emp_brand_new" : (h === "Name" ? "Brand New Person" : "")));
      sheets.Employees = [header, updatedRow.map((c, i) => (header[i] === "Name" ? "Renamed Via Import" : c)), newRow];

      const parsed = IO.parseWorkbook(sheets, state.settings, null);
      // Apply exactly like ROE.ui.applyImport does.
      parsed.bySheet.Employees.records.forEach((rec) => STORE.upsert("employees", rec));

      const after = STORE.getState().employees;
      return {
        before, after: after.length,
        untouchedStillPresent: after.some((e) => e.id === untouchedId),
        renamedApplied: after.find((e) => e.id === updatedExisting.id).name === "Renamed Via Import",
        newInserted: after.some((e) => e.id === "emp_brand_new"),
      };
    });
    expect(result.after).toBe(result.before + 1); // one insert, rest untouched
    expect(result.untouchedStillPresent).toBe(true);
    expect(result.renamedApplied).toBe(true);
    expect(result.newInserted).toBe(true);
  });

  test("downloaded template imports cleanly as a no-op (all EXAMPLE- rows skipped)", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const IO = window.ROE.io;
      const settings = { schemaVersion: 1, horizonStart: "2026-01", horizonMonths: 12 };
      const templateSheets = IO.buildTemplateSheets(settings);
      const parsed = IO.parseWorkbook(templateSheets, settings, null);
      const totalRecords = Object.values(parsed.bySheet).reduce((s, r) => s + r.records.length, 0);
      const totalSkipped = Object.values(parsed.bySheet).reduce((s, r) => s + r.skipped, 0);
      const totalErrors = Object.values(parsed.bySheet).reduce((s, r) => s + r.errors.length, 0);
      return { totalRecords, totalSkipped, totalErrors };
    });
    expect(result.totalRecords, "template import should insert nothing (pure no-op)").toBe(0);
    expect(result.totalSkipped).toBeGreaterThan(0);
    expect(result.totalErrors).toBe(0);
  });

  test("month columns outside the horizon are reported and skipped, not silently dropped", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const IO = window.ROE.io;
      const settings = { horizonStart: "2026-01", horizonMonths: 3 }; // 2026-01..2026-03
      const aoa = [
        ["DemandID", "ProjectID", "Title", "Discipline", "MinLevel", "Openings", "RequiredSkills", "2026-01", "2026-02", "2099-12"],
        ["dem_x", "prj_x", "Test Demand", "Civil", "Junior", 1, "", 50, 50, 999],
      ];
      const parsed = IO.parseWorkbook({ ProjectDemands: aoa }, settings, null);
      return { monthWarnings: parsed.monthWarnings, record: parsed.bySheet.ProjectDemands.records[0] };
    });
    expect(result.monthWarnings.length).toBeGreaterThan(0);
    expect(result.monthWarnings[0].headers).toContain("2099-12");
    expect(result.record.allocationByMonth["2099-12"]).toBeUndefined();
    expect(result.record.allocationByMonth["2026-01"]).toBe(50);
  });

  test("renamed headers import correctly once mapped (column-mapping UI)", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const IO = window.ROE.io;
      const settings = { horizonStart: "2026-01", horizonMonths: 3 };
      const aoa = [
        ["Emp Id", "Full Name", "E-mail"], // non-canonical headers
        ["emp_1", "Renamed Header Person", "person@example.com"],
      ];
      const detected = IO.detectMapping("Employees", aoa[0]);
      // Manually complete the mapping the way the mapping UI would (name/email auto-detected via
      // fuzzy match; confirm at least id gets mapped by the user).
      const mapping = Object.assign({}, detected, { EmployeeID: "Emp Id", Name: "Full Name", Email: "E-mail" });
      const parsed = IO.parseSheet("Employees", aoa, { mapping, monthKeys: [] });
      return { record: parsed.records[0], errors: parsed.errors };
    });
    expect(result.errors).toEqual([]);
    expect(result.record.id).toBe("emp_1");
    expect(result.record.name).toBe("Renamed Header Person");
    expect(result.record.email).toBe("person@example.com");
  });
});

test.describe("Vendor degradation for import/export (§9 Global)", () => {
  test("with SheetJS blocked (real CDN state in this sandbox): export/import controls are disabled with a visible explanation, no exception on click", async ({ page }) => {
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);
    const xlsxAvailable = await page.evaluate(() => !!window.XLSX);
    expect(xlsxAvailable, "this test assumes the CDN is actually blocked in this environment").toBe(false);

    const exportDisabled = await page.locator("#btn-export-xlsx").isDisabled();
    const importDisabled = await page.locator("#import-file").isDisabled();
    expect(exportDisabled).toBe(true);
    expect(importDisabled).toBe(true);
    expect(errors).toEqual([]);
  });

  test("NOTE: CSV per-sheet export is disabled whenever XLSX fails to load, even though buildCsvForSheet has no dependency on window.XLSX", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);
    const xlsxAvailable = await page.evaluate(() => !!window.XLSX);
    expect(xlsxAvailable).toBe(false);
    const csvDisabled = await page.locator("#btn-export-csv").isDisabled();
    // This matches the letter of §9 ("charts and import/export are disabled"), so it is not scored
    // as a failure, but it is a missed opportunity: CSV export/downloadText never touches
    // window.XLSX at all and could remain available during a CDN outage.
    expect(csvDisabled).toBe(true);
  });
});
