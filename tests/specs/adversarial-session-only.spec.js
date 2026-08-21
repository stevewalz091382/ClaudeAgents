// ADVERSARIAL re-test, written by the Tester independently (not trusting the Coder's spec).
// Realistic sequence the Coder's own "OFF" test does NOT cover: toggle ON, RELOAD (so the
// in-memory store genuinely starts empty per the new session-only-boot behavior), THEN toggle
// OFF from that empty in-memory state, and see whether the pending debounced persist() wipes
// out the previously-saved IndexedDB data with the now-empty in-memory arrays.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("ADVERSARIAL: session-only toggle OFF after a reload while in-memory is empty", () => {
  test("toggle ON -> reload (in-memory empty, IDB still has data) -> toggle OFF -> wait for debounce -> reload again: does old data survive?", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // persisted: ~40 employees now in IndexedDB

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(200);

    // Reload #1: per the fix, in-memory should now be empty, IDB should still hold the old data.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const inMemoryAfterFirstReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    const idbAfterFirstReload = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    console.log("in-memory after 1st reload:", inMemoryAfterFirstReload, "| IDB after 1st reload:", idbAfterFirstReload);
    expect(inMemoryAfterFirstReload).toBe(0);
    expect(idbAfterFirstReload).toBeGreaterThan(0); // old data must still be sitting there untouched

    // Now toggle session-only OFF from this (empty in-memory) state via the real checkbox.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").uncheck();
    // Give the 400ms debounced scheduleSave a chance to fire persist() with whatever is
    // currently in memory (which is empty at this point).
    await page.waitForTimeout(700);

    const idbRightAfterToggleOff = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    console.log("IDB right after toggling OFF from empty in-memory state:", idbRightAfterToggleOff);

    // Reload #2: with sessionOnly now false, load() should read from IndexedDB again.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const employeesAfterSecondReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    const idbAfterSecondReload = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    console.log("in-memory after 2nd reload:", employeesAfterSecondReload, "| IDB after 2nd reload:", idbAfterSecondReload);

    expect(employeesAfterSecondReload, "the originally-persisted demo data must survive the ON->reload->OFF sequence, not be silently wiped by a stale-empty scheduleSave").toBeGreaterThan(0);
  });
});
