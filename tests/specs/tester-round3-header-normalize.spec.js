// Ports the Tester's ROUND 3 scratch probes (TEST_REPORT.md, "RE-TEST pass ROUND 3", findings #1
// and #2) into the committed suite.
//
// Root cause: the header-verification checks added in fix round 2 (readCustom's mismatch check
// around index.html:1743, and detectMapping's custom-column reservation check around :1635)
// compared header text with byte-exact `===`/`String(...)` equality instead of the same
// `U.normalizeHeader` helper (lowercase, strip non-alphanumerics) that canonical-column matching
// already uses three lines above (:1619). Fix: both sites now use `U.normalizeHeader(...) ===
// U.normalizeHeader(...)`, matching canonical-column matching's tolerance.
//
// - #1 (HIGH): a case-only difference between a custom column's header and its stored def.label
//   (e.g. "Office Location" vs "office location") used to fail the exact-match check, falling the
//   column into the fuzzy-candidate pool. Combined with a deleted canonical column ("Office") that
//   the mangled header fuzzy-resembles, fuzzyMatchHeader stole the column into the canonical field,
//   silently corrupting canonical data and losing the custom value, with zero reported errors.
// - #2 (LOW): a merely whitespace-padded (but otherwise correct) header used to produce a spurious
//   "column mismatch" error instead of matching correctly.
const { test, expect } = require("@playwright/test");
const { loadApp } = require("../helpers/loadApp");

test.describe("TESTER-R3-1 (HIGH): case-only header difference must not let fuzzy matching steal the column into a deleted canonical field", () => {
  test("lowercasing a custom column's header while deleting the canonical column it now fuzzy-resembles still matches the custom column correctly - no fuzzy theft, no silent corruption", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Office Location", "text");
      const def = STORE.getState().customFieldDefs[0];
      const emp = M.newEmployee({ name: "Case Person", office: "HQ", custom: { [def.key]: "Denver" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const header = sheets.Employees[0].slice();
      const officeIdx = header.indexOf("Office");
      const customIdx = header.indexOf("Office Location");
      // Delete the canonical "Office" column entirely AND lowercase the custom column's header
      // text (as if a user retyped/re-cased the header in Excel, or Excel autocapitalized it).
      let editedHeader = header.slice();
      editedHeader[customIdx] = "office location"; // case-different, same text otherwise
      editedHeader = editedHeader.slice(0, officeIdx).concat(editedHeader.slice(officeIdx + 1));

      const editedRows = sheets.Employees.slice(1).map((row) => {
        let r = row.slice();
        r = r.slice(0, officeIdx).concat(r.slice(officeIdx + 1));
        return r;
      });
      const editedAoa = [editedHeader].concat(editedRows);

      const parsed = IO.parseWorkbook(
        { Employees: editedAoa, CustomFieldDefs: sheets.CustomFieldDefs },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      return {
        key: def.key,
        officeAfterReparse: empRow ? empRow.office : undefined,
        customAfterReparse: empRow ? empRow.custom : undefined,
        errors: parsed.bySheet.Employees.errors,
      };
    });
    console.log("TESTER-R3-1 result:", JSON.stringify(result));
    // The canonical "Office" field must NOT be silently overwritten with the custom column's value:
    // with "Office" deleted from the file entirely, it should be unmapped (undefined), never "Denver".
    expect(result.officeAfterReparse).not.toBe("Denver");
    // The custom column must be recognized (case-insensitively) and its value correctly read, not lost.
    expect(result.customAfterReparse).toBeTruthy();
    expect(result.customAfterReparse[result.key]).toBe("Denver");
  });
});

test.describe("TESTER-R3-2 (LOW): whitespace-padded header must match, not produce a spurious mismatch error", () => {
  test("a leading/trailing-whitespace-padded custom column header matches its def and imports the new value, instead of reporting a false mismatch", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      STORE.addFieldDef("Employee", "Region", "text");
      const def = STORE.getState().customFieldDefs[0];
      const emp = M.newEmployee({ name: "WS Person", custom: { [def.key]: "West" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const header = sheets.Employees[0].slice();
      const idx = header.indexOf("Region");
      const editedHeader = header.slice();
      editedHeader[idx] = " Region "; // whitespace padded, common Excel copy/paste artifact
      // Change the cell value too, so we can confirm the NEW value is imported (proving a real
      // match happened), not just that the old value survived untouched.
      const editedRows = sheets.Employees.slice(1).map((row) => {
        const r = row.slice();
        r[idx] = "East-Updated";
        return r;
      });
      const editedAoa = [editedHeader].concat(editedRows);

      const parsed = IO.parseWorkbook(
        { Employees: editedAoa, CustomFieldDefs: sheets.CustomFieldDefs },
        STORE.getState().settings, null, STORE.getState().customFieldDefs
      );
      const empRow = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);
      return {
        key: def.key,
        errors: parsed.bySheet.Employees.errors,
        parsedCustom: empRow ? empRow.custom : undefined,
      };
    });
    console.log("TESTER-R3-2 result:", JSON.stringify(result));
    // No spurious mismatch error should be reported for a whitespace-only header difference.
    expect(result.errors.length).toBe(0);
    // The new cell value must be imported, proving the whitespace-padded header actually matched.
    expect(result.parsedCustom[result.key]).toBe("East-Updated");
  });
});
