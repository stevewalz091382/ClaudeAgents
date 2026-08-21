// ADVERSARIAL round-2 re-test, written independently by the Tester (not derived from the Coder's
// specs). Targets scenarios the Coder's fix-loop-2 patch does not appear to have tested:
//   (a) toggle ON -> (no reload) -> add data -> toggle OFF -> (no reload): does the "private"
//       data added while session-only was on get written to IndexedDB immediately, contradicting
//       both the session-only privacy intent and the freshly-updated UI hint text?
//   (b) toggle ON from a totally empty app -> add new data while ON -> turn OFF -> reload: does
//       the new data appropriately vanish (never persisted), and does pre-existing data (if any)
//       come back correctly?
//   (c) repeat-each stability of the fixed toggle-OFF-after-reload sequence.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("ADVERSARIAL round 2: session-only edge cases not covered by fix-loop-2's own tests", () => {

  test("(a) toggle ON, add data, toggle OFF -- all within the SAME session, never reloading -- must not silently persist the 'private' addition", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // ~40 employees now genuinely in IndexedDB, hydrated=true

    const idbBefore = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbBefore).toBeGreaterThan(0);

    // Turn session-only ON via the real checkbox.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(100);

    // Add a new employee WHILE session-only is on, believing it's private/non-persisted.
    const newId = await page.evaluate(() => {
      var id = "adversarial-private-" + Date.now();
      window.ROE.store.upsert("employees", {
        id: id, name: "Should Not Persist", role: "Engineer", disciplines: [], skills: {},
        capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: []
      });
      return id;
    });
    await page.waitForTimeout(100);

    // Turn session-only OFF again, still within the SAME session, no reload in between.
    await page.locator("#set-sessionOnly").uncheck();
    // Give the 400ms debounce well past enough time to fire if scheduleSave() was allowed to run.
    await page.waitForTimeout(700);

    const idbAfterToggleOff = await page.evaluate(async () => await window.ROE.db.readAll("employees"));
    const idsAfter = idbAfterToggleOff.map(function(e){ return e.id; });
    console.log("IDB employee count after ON->add->OFF (no reload):", idbAfterToggleOff.length, "contains new record:", idsAfter.indexOf(newId) !== -1);

    // The whole point of session-only mode is that data added while it's on should never reach
    // disk unless the user later does something that legitimately re-enables persistence AND is
    // told that's what's happening. Silently writing it the instant the checkbox is unchecked
    // (with no reload, no re-hydration, no warning) defeats the privacy guarantee.
    expect(idsAfter.indexOf(newId), "the record added while session-only was ON must not be silently written to IndexedDB the moment the checkbox is unchecked, without any reload or explicit re-save action").toBe(-1);
  });

  test("(b) toggle ON from empty app, add data while ON, turn OFF, reload: new data must vanish; pre-existing data (none here) stays absent", async ({ page }) => {
    await loadApp(page);
    // Do NOT load demo data - start from a genuinely empty app/IndexedDB.
    const idbEmptyAtStart = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbEmptyAtStart).toBe(0);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(100);

    await page.evaluate(() => {
      window.ROE.store.upsert("employees", {
        id: "ephemeral-1", name: "Ephemeral", role: "Engineer", disciplines: [], skills: {},
        capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: []
      });
    });
    await page.waitForTimeout(100);
    const inMemoryWhileOn = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(inMemoryWhileOn).toBe(1); // sanity: the add worked in memory

    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(700); // let any (mis)fired debounce complete

    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const employeesAfterReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    const idbAfterReload = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    console.log("after ON(empty)->add->OFF->reload: in-memory =", employeesAfterReload, "| IDB =", idbAfterReload);
    expect(employeesAfterReload, "data added while session-only was ON, in an app that started empty, must not survive a reload after toggling OFF").toBe(0);
    expect(idbAfterReload, "IndexedDB itself must not have picked up the ephemeral record either").toBe(0);
  });

  test("(c) repeat stability: the fixed ON->reload->OFF->reload sequence preserves pre-existing data across 3 repeated attempts", async ({ page }) => {
    for (let i = 0; i < 3; i++) {
      await loadApp(page);
      await loadDemoData(page);
      await page.waitForTimeout(600);

      await page.evaluate(() => { location.hash = "#settings"; });
      await page.waitForTimeout(150);
      await page.locator("#set-sessionOnly").check();
      await page.waitForTimeout(200);

      await page.reload({ waitUntil: "load" });
      await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
      await page.waitForTimeout(400);

      await page.evaluate(() => { location.hash = "#settings"; });
      await page.waitForTimeout(150);
      await page.locator("#set-sessionOnly").uncheck();
      await page.waitForTimeout(700);

      await page.reload({ waitUntil: "load" });
      await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
      await page.waitForTimeout(500);

      const employeesAfter = await page.evaluate(() => window.ROE.store.getState().employees.length);
      console.log("iteration", i, "employees after full ON/reload/OFF/reload cycle:", employeesAfter);
      expect(employeesAfter, "iteration " + i + ": data must survive the full toggle cycle").toBeGreaterThan(0);

      // Clean slate for next iteration.
      page.once("dialog", async (dialog) => { await dialog.accept("CLEAR"); });
      await page.click("#btn-clear-all");
      await page.waitForTimeout(400);
    }
  });
});
