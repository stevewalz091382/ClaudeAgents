const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test("Flip-flop: toggle ON, OFF, ON again before ever reloading -> final pref (ON) wins on reload", async ({ page }) => {
  await loadApp(page);
  await loadDemoData(page);
  await page.waitForTimeout(600);
  await page.evaluate(() => { location.hash = "#settings"; });
  await page.waitForTimeout(150);
  const box = page.locator("#set-sessionOnly");
  await box.check();
  await page.waitForTimeout(50);
  await box.uncheck();
  await page.waitForTimeout(50);
  await box.check();
  await page.waitForTimeout(300); // let all async savePreference calls settle
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
  await page.waitForTimeout(300);
  const count = await page.evaluate(() => window.ROE.store.getState().employees.length);
  const active = await page.evaluate(() => window.ROE.store.isPersistenceActive());
  console.log("Flip-flop final state: in-memory count=", count, "isPersistenceActive=", active);
  expect(count, "final toggle state was ON (session-only) so reload should start empty").toBe(0);
  expect(active).toBe(false);
});

test("Flip-flop: toggle ON, OFF again before ever reloading -> final pref (OFF) wins on reload", async ({ page }) => {
  await loadApp(page);
  await loadDemoData(page);
  await page.waitForTimeout(600);
  const before = await page.evaluate(() => window.ROE.store.getState().employees.length);
  await page.evaluate(() => { location.hash = "#settings"; });
  await page.waitForTimeout(150);
  const box = page.locator("#set-sessionOnly");
  await box.check();
  await page.waitForTimeout(50);
  await box.uncheck();
  await page.waitForTimeout(300);
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
  await page.waitForTimeout(300);
  const count = await page.evaluate(() => window.ROE.store.getState().employees.length);
  const active = await page.evaluate(() => window.ROE.store.isPersistenceActive());
  console.log("Flip-flop2 final state: in-memory count=", count, "isPersistenceActive=", active);
  expect(count).toBe(before);
  expect(active).toBe(true);
});
