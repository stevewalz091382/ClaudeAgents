const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test("RACE: reload immediately after toggling session-only ON with zero delay", async ({ page }) => {
  await loadApp(page);
  await loadDemoData(page);
  await page.waitForTimeout(600);
  await page.evaluate(() => { location.hash = "#settings"; });
  await page.waitForTimeout(150);
  await page.locator("#set-sessionOnly").check();
  // NO waitForTimeout at all - reload as fast as humanly/programmatically possible
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
  await page.waitForTimeout(300);
  const empty = await page.evaluate(() => window.ROE.store.getState().employees.length);
  console.log("RACE result (0ms delay before reload): in-memory employees after reload =", empty);
});

test("RACE: reload after toggling with 10ms delay", async ({ page }) => {
  await loadApp(page);
  await loadDemoData(page);
  await page.waitForTimeout(600);
  await page.evaluate(() => { location.hash = "#settings"; });
  await page.waitForTimeout(150);
  await page.locator("#set-sessionOnly").check();
  await page.waitForTimeout(10);
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
  await page.waitForTimeout(300);
  const empty = await page.evaluate(() => window.ROE.store.getState().employees.length);
  console.log("RACE result (10ms delay before reload): in-memory employees after reload =", empty);
});
