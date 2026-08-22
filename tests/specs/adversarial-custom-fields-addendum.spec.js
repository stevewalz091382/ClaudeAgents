// Adversarial tests for BUILD_PLAN_ADDENDUM_1.md, independent of the Coder's own
// tests/specs/custom-fields-addendum.spec.js. Written by the Tester to actively try to break the
// custom-fields/migration/Assignment/Skill/workbook-IO feature set.
const { test, expect } = require("@playwright/test");
const path = require("path");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("ADVERSARIAL: workbook custom-field header collisions (IO-1)", () => {
  test("BUG CHECK: two custom fields on the same entity sharing an identical LABEL (different generated keys) corrupt each other on export/re-import because readCustom matches columns by header===label, not by key", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      // Two Employee custom fields, same label "Region", forced key collision -> auto-suffixed.
      STORE.addFieldDef("Employee", "Region", "text");
      STORE.addFieldDef("Employee", "Region", "text");
      const defs = STORE.getState().customFieldDefs;
      const keyA = defs[0].key, keyB = defs[1].key;
      const emp = M.newEmployee({ name: "Dual Region Person", custom: { [keyA]: "East", [keyB]: "West" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const header = sheets.Employees[0];
      const row = sheets.Employees.find((r) => r[0] === emp.id);

      const parsed = IO.parseWorkbook(sheets, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      const reparsed = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);

      return { keyA, keyB, header, rowRegionCols: header.map((h, i) => (h === "Region" ? row[i] : null)).filter((v) => v !== null), reparsedCustom: reparsed.custom };
    });
    console.log("dual-label result:", JSON.stringify(result));
    // Both original values were written to the sheet (data itself is present)...
    expect(result.rowRegionCols).toEqual(["East", "West"]);
    // ...but on re-import, do BOTH keys recover their own distinct value?
    // If this fails, it demonstrates data corruption: one key silently gets the other's value,
    // or both keys collapse to the same value.
    expect(result.reparsedCustom[result.keyA]).toBe("East");
    expect(result.reparsedCustom[result.keyB]).toBe("West");
  });

  test("BUG CHECK: a custom field label identical to a canonical column name ('Name') causes readCustom to read the WRONG column on import", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io, M = window.ROE.model;
      // Nothing in the Manage Fields UI stops a user from labeling a custom field "Name".
      STORE.addFieldDef("Employee", "Name", "text");
      const def = STORE.getState().customFieldDefs[0];
      const emp = M.newEmployee({ name: "Real Employee Name", custom: { [def.key]: "CUSTOM_FIELD_VALUE" } });
      STORE.upsert("employees", emp);

      const sheets = IO.buildWorkbookSheets(STORE.getState());
      const parsed = IO.parseWorkbook(sheets, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      const reparsed = parsed.bySheet.Employees.records.find((r) => r.id === emp.id);

      return {
        header: sheets.Employees[0],
        key: def.key,
        canonicalNameAfterReparse: reparsed.name,
        customValueAfterReparse: reparsed.custom ? reparsed.custom[def.key] : undefined,
      };
    });
    console.log("name-collision result:", JSON.stringify(result));
    // Canonical Name must still be the employee's real name...
    expect(result.canonicalNameAfterReparse).toBe("Real Employee Name");
    // ...and the custom field (also labeled "Name") must round-trip its OWN distinct value, not
    // silently pick up the canonical Name column's value.
    expect(result.customValueAfterReparse).toBe("CUSTOM_FIELD_VALUE");
  });
});

test.describe("ADVERSARIAL: re-importing a workbook must never silently erase existing custom values not present in the file", () => {
  test("BUG CHECK: re-importing an import file with NO custom columns (e.g. an older export, or a partial re-export) wipes out an existing record's stored custom values via full-record overwrite", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, IO = window.ROE.io;
      STORE.addFieldDef("Employee", "Badge Number", "number");
      const emp = STORE.getState().employees[0];
      emp.custom = { badge_number: 555 };
      STORE.upsert("employees", emp);
      const empId = emp.id;

      // Simulate re-importing a workbook that has ZERO custom columns for Employees (as if
      // exported before this field existed, or hand-edited to remove the column) but otherwise
      // contains a legitimate, unchanged row for the SAME employee ID.
      const aoa = [
        ["EmployeeID", "Name", "Email", "Level", "Discipline", "Office", "BusinessGroup", "TargetUtil", "MentorRole", "Active", "Notes"],
        [empId, emp.name, emp.email, emp.level, emp.discipline, emp.office, emp.businessGroup, emp.targetUtil, emp.mentorRole, emp.active, emp.notes],
      ];
      const parsed = IO.parseWorkbook({ Employees: aoa }, STORE.getState().settings, null, STORE.getState().customFieldDefs);
      // Mirror applyImport() exactly.
      if (parsed.fieldDefs && parsed.fieldDefs.toAdd.length) STORE.restoreFieldDefs(parsed.fieldDefs.toAdd);
      parsed.bySheet.Employees.records.forEach((rec) => STORE.upsert("employees", rec));

      const after = STORE.getState().employees.find((e) => e.id === empId);
      return { customAfter: after.custom, defsStillExist: STORE.getState().customFieldDefs.length };
    });
    console.log("re-import wipe result:", JSON.stringify(result));
    expect(result.defsStillExist).toBeGreaterThan(0); // field def itself survives (per CF-2)
    // The already-stored value must survive a re-import that simply doesn't mention it.
    expect(result.customAfter).toEqual({ badge_number: 555 });
  });
});

test.describe("ADVERSARIAL: custom field def re-add with the same generated key must repopulate the form from the surviving stored value", () => {
  test("real UI: remove a field def, re-add one with the identical label, reopening the record's edit form shows the OLD value already populated (not blank)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#skills"; });
    await page.waitForTimeout(200);

    await page.click("#btn-manage-emp-fields");
    await page.fill("#mf-label", "Badge Number");
    await page.selectOption("#m-mf-type", "number");
    await page.click("#mf-add");
    await page.waitForTimeout(100);
    await page.click("#mf-close");
    await page.waitForTimeout(100);

    const empId = await page.locator(".edit-emp").first().getAttribute("data-id");
    await page.locator(".edit-emp").first().click();
    await page.waitForSelector('.custom-field-input[data-entity="Employee"]');
    await page.fill('.custom-field-input[data-entity="Employee"][data-key="badge_number"]', "999");
    await page.click("#m-save");
    await page.waitForTimeout(150);

    // Remove the def.
    page.once("dialog", (d) => d.accept());
    await page.click("#btn-manage-emp-fields");
    await page.click(".mf-remove");
    await page.waitForTimeout(100);

    // Re-add a field with the EXACT same label (regenerates the same key, "badge_number", since
    // no collision exists in the defs array anymore).
    await page.fill("#mf-label", "Badge Number");
    await page.selectOption("#m-mf-type", "number");
    await page.click("#mf-add");
    await page.waitForTimeout(100);
    await page.click("#mf-close");
    await page.waitForTimeout(100);

    const newKey = await page.evaluate(() => window.ROE.store.listFieldDefs("Employee")[0].key);
    expect(newKey).toBe("badge_number");

    await page.locator(".edit-emp").first().click();
    await page.waitForSelector('.custom-field-input[data-entity="Employee"][data-key="badge_number"]');
    const repopulatedValue = await page.locator('.custom-field-input[data-entity="Employee"][data-key="badge_number"]').inputValue();
    console.log("repopulated value after remove+re-add same key:", repopulatedValue);
    expect(repopulatedValue).toBe("999");
  });
});

test.describe("ADVERSARIAL: 'Unknown skill' claim for orphaned skill references", () => {
  test("deleting a referenced skill never actually renders the text 'Unknown skill' anywhere in the reachable UI, despite the confirm-dialog and self-report claiming it does", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const targetSkillId = await page.evaluate(() => window.ROE.store.getState().skills[0].id);
    page.once("dialog", (d) => d.accept());
    await page.evaluate(() => { location.hash = "#skills"; });
    await page.waitForTimeout(200);
    await page.click(`.delete-skill[data-id="${targetSkillId}"]`);
    await page.waitForTimeout(200);

    // Walk every panel looking for the literal string "Unknown skill" anywhere in rendered text.
    const panels = ["overview", "skills", "projects", "optimizer", "mentorship", "timeline", "alerts", "settings"];
    let found = false;
    for (const p of panels) {
      await page.evaluate((panel) => { location.hash = "#" + panel; }, p);
      await page.waitForTimeout(150);
      const text = await page.evaluate(() => document.body.innerText);
      if (text.includes("Unknown skill")) { found = true; break; }
    }
    console.log("'Unknown skill' text ever rendered in UI:", found);
    // This assertion is EXPECTED TO FAIL if the claim is false - documenting the gap.
    expect(found).toBe(true);
  });
});

test.describe("ADVERSARIAL: TRUE schema migration (real onupgradeneeded from an actual v1-shaped IndexedDB, not a faked meta flag)", () => {
  test("a genuinely v1 IndexedDB (customFieldDefs store absent, created BEFORE the app ever runs its own boot code) migrates via the real onupgradeneeded generic-creation path with zero data loss, and a second reload is a stable no-op", async ({ page }) => {
    const indexUrl = "file://" + path.resolve(__dirname, "..", "..", "index.html");

    // Serve an inert stub for the app's first navigation so we get the real file:// origin's
    // storage partition WITHOUT the app's own boot script ever running and creating the v2 DB
    // first. This lets us seed a truly pre-addendum (v1) IndexedDB from a clean slate.
    await page.route(indexUrl, (route) => route.fulfill({ contentType: "text/html", body: "<html><body>prep</body></html>" }));
    await page.goto(indexUrl, { waitUntil: "load" });

    const seed = {
      employees: [
        { id: "emp_v1_1", name: "V1 Alice", email: "alice@x.com", level: "Senior", discipline: "Civil", office: "HQ", businessGroup: "Transportation", targetUtil: 85, mentorRole: "None", active: true, notes: "" },
        { id: "emp_v1_2", name: "V1 Bob", email: "bob@x.com", level: "Junior", discipline: "Structural", office: "HQ", businessGroup: "Water", targetUtil: 80, mentorRole: "None", active: true, notes: "" },
      ],
      projects: [{ id: "prj_v1_1", name: "V1 Project", client: "Acme", market: "Water", discipline: "Civil", phase: "Design", budget: 100000, bimLevel: "LOD300", teamMin: 1, teamMax: 5, priority: 3, status: "Active", software: [], notes: "" }],
      demands: [{ id: "dem_v1_1", projectId: "prj_v1_1", title: "V1 Demand", discipline: "Civil", minLevel: "Junior", openings: 1, requiredSkills: [], allocationByMonth: { "2026-01": 50 } }],
      assignments: [{ id: "asg_v1_1", projectId: "prj_v1_1", employeeId: "emp_v1_1", demandId: "dem_v1_1", status: "Committed", source: "manual", scoreSnapshot: null, allocationByMonth: { "2026-01": 50 } }],
      mentorships: [{ id: "men_v1_1", mentorId: "emp_v1_1", menteeId: "emp_v1_2", focusSkillId: "skl_v1_1", sharedProjectId: "prj_v1_1", frequency: "Weekly", score: 70, compat: "High", status: "Active" }],
      skills: [{ id: "skl_v1_1", code: "REVIT", name: "Revit", category: "BIM" }, { id: "skl_v1_2", code: "GIS", name: "GIS", category: "Data" }],
      employeeSkills: [{ employeeId: "emp_v1_1", skillId: "skl_v1_1", level: 4 }, { employeeId: "emp_v1_2", skillId: "skl_v1_2", level: 2 }],
      settings: { horizonStart: "2026-01", horizonMonths: 6, theme: "dark", sessionOnly: false },
    };

    const rebuildResult = await page.evaluate(async (snapshot) => {
      function promisifyTx(tx) {
        return new Promise((resolve, reject) => { tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error); });
      }
      const OLD_STORE_DEFS = [
        { name: "employees", opts: { keyPath: "id" } },
        { name: "projects", opts: { keyPath: "id" } },
        { name: "demands", opts: { keyPath: "id" } },
        { name: "assignments", opts: { keyPath: "id" } },
        { name: "mentorships", opts: { keyPath: "id" } },
        { name: "skills", opts: { keyPath: "id" } },
        { name: "employeeSkills", opts: {} },
        { name: "settings", opts: {} },
        { name: "meta", opts: {} },
      ]; // deliberately NO customFieldDefs store - a real pre-addendum v1 shape

      const db = await new Promise((resolve, reject) => {
        const req = indexedDB.open("roe", 1);
        req.onupgradeneeded = (e) => {
          const d = e.target.result;
          OLD_STORE_DEFS.forEach((def) => { if (!d.objectStoreNames.contains(def.name)) d.createObjectStore(def.name, def.opts); });
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });

      const tx = db.transaction(OLD_STORE_DEFS.map((d) => d.name), "readwrite");
      snapshot.employees.forEach((r) => tx.objectStore("employees").put(r));
      snapshot.projects.forEach((r) => tx.objectStore("projects").put(r));
      snapshot.demands.forEach((r) => tx.objectStore("demands").put(r));
      snapshot.assignments.forEach((r) => tx.objectStore("assignments").put(r));
      snapshot.mentorships.forEach((r) => tx.objectStore("mentorships").put(r));
      snapshot.skills.forEach((r) => tx.objectStore("skills").put(r));
      snapshot.employeeSkills.forEach((r) => tx.objectStore("employeeSkills").put(r, r.employeeId + "|" + r.skillId));
      tx.objectStore("settings").put(snapshot.settings, "app");
      tx.objectStore("meta").put({ schemaVersion: 1 }, "schemaVersion");
      await promisifyTx(tx);

      const storeNamesBeforeReload = Array.from(db.objectStoreNames);
      db.close();
      return { storeNamesBeforeReload };
    }, seed);

    expect(rebuildResult.storeNamesBeforeReload).not.toContain("customFieldDefs");
    expect(rebuildResult.storeNamesBeforeReload.sort()).toEqual(["assignments", "demands", "employeeSkills", "employees", "meta", "mentorships", "projects", "settings", "skills"].sort());

    // Now unroute and load the REAL app for the first time against this pre-seeded v1 database.
    await page.unroute(indexUrl);
    await page.goto(indexUrl, { waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(700);

    const after = await page.evaluate(() => {
      const s = window.ROE.store.getState();
      return {
        employees: s.employees.length, projects: s.projects.length, demands: s.demands.length,
        assignments: s.assignments.length, mentorships: s.mentorships.length, skills: s.skills.length,
        employeeSkills: s.employeeSkills.length, customFieldDefs: s.customFieldDefs,
        empName: (s.employees.find((e) => e.id === "emp_v1_1") || {}).name,
      };
    });
    const schemaVersionAfter = await page.evaluate(async () => (await window.ROE.db.getRecord("meta", "schemaVersion")).schemaVersion);

    console.log("TRUE migration - after:", JSON.stringify(after), "schemaVersionAfter:", schemaVersionAfter);

    expect(after.employees).toBe(2);
    expect(after.projects).toBe(1);
    expect(after.demands).toBe(1);
    expect(after.assignments).toBe(1);
    expect(after.mentorships).toBe(1);
    expect(after.skills).toBe(2);
    expect(after.employeeSkills).toBe(2);
    expect(after.empName).toBe("V1 Alice");
    expect(after.customFieldDefs).toEqual([]);
    expect(schemaVersionAfter).toBe(2);

    // Second reload must be a stable no-op: no re-migration side effects, data still intact.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const stable = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(stable).toBe(2);
  });
});

test.describe("ADVERSARIAL: deterministic (not probabilistic) capacity-overage warning for manual Assignment", () => {
  test("a manual allocation forced to guaranteed exceed effectiveCapacity (low targetUtil + 100% alloc, zero pre-existing load) ALWAYS produces the warning toast, and the assignment is still saved", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);

    const setup = await page.evaluate(() => {
      const STORE = window.ROE.store;
      const s = STORE.getState();
      const emp = s.employees[0];
      emp.targetUtil = 15;
      STORE.upsert("employees", emp);
      const toRemove = s.assignments.filter((a) => a.employeeId === emp.id).map((a) => a.id);
      toRemove.forEach((id) => STORE.remove("assignments", id));
      const project = s.projects[0];
      const month = window.ROE.util.monthKeys(s.settings.horizonStart, s.settings.horizonMonths)[0];
      return { employeeId: emp.id, projectId: project.id, month };
    });

    await page.evaluate(() => { location.hash = "#projects"; });
    await page.waitForTimeout(200);
    await page.click(`.edit-prj[data-id="${setup.projectId}"]`);
    await page.waitForSelector("#btn-add-assignment");
    await page.click("#btn-add-assignment");
    await page.waitForSelector("#a-employee");
    await page.selectOption("#a-employee", setup.employeeId);
    await page.locator(".asg-month-input").first().fill("100");

    // Let any lingering toasts (e.g. from earlier setup) clear, then count from a clean baseline
    // so we grab the toast that appears BECAUSE of this Save click, not a stale one.
    await page.waitForTimeout(4100);
    const beforeCount = await page.locator(".toast").count();
    await page.click("#m-save");
    await page.waitForFunction((n) => document.querySelectorAll(".toast").length > n, beforeCount, { timeout: 3000 }).catch(() => {});
    const toasts = await page.locator(".toast").allTextContents();
    const toastText = toasts.join(" | ");
    console.log("deterministic capacity toast text(s):", toastText);

    expect(toastText.toLowerCase()).toContain("capacity");

    const saved = await page.evaluate((pid) => window.ROE.store.getState().assignments.some((a) => a.projectId === pid && a.allocationByMonth), setup.projectId);
    expect(saved).toBe(true);
  });
});

test.describe("ADVERSARIAL: XSS / injection through custom field labels and values", () => {
  test("a custom field label containing HTML/script is escaped in the Manage Fields table and in the form input, never executed or breaking the DOM", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#skills"; });
    await page.waitForTimeout(200);

    let dialogFired = false;
    page.on("dialog", (d) => { dialogFired = true; d.dismiss(); });

    await page.click("#btn-manage-emp-fields");
    await page.fill("#mf-label", '<img src=x onerror="window.__xss=true">');
    await page.click("#mf-add");
    await page.waitForTimeout(150);

    const xssRan = await page.evaluate(() => window.__xss === true);
    expect(xssRan).toBe(false);
    expect(dialogFired).toBe(false);

    // The label must render as inert text in the Manage Fields table, not as a live <img> tag.
    const imgCount = await page.locator("#mf-close").locator("xpath=..").locator("img").count();
    expect(imgCount).toBe(0);
  });
});
