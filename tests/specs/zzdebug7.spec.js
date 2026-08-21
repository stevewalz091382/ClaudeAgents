const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test("preset save/reload with non-100-summing raw weights", async ({ page }) => {
  await loadApp(page);
  await loadDemoData(page);
  await page.waitForTimeout(300);
  await page.evaluate(() => { location.hash = "#optimizer"; });
  await page.waitForTimeout(300);
  // Set sliders to 10/10/10/10 (sum=40, does not sum to 100).
  for (const k of ["skill","availability","seniority","discipline"]) {
    await page.locator("#w-" + k).fill("10");
    await page.locator("#w-" + k).dispatchEvent("input");
  }
  await page.waitForTimeout(100);
  page.once("dialog", async (d) => { await d.accept("MyWeirdPreset"); });
  await page.click("#opt-save-preset");
  await page.waitForTimeout(300);

  // Reload the whole page (real user reload).
  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
  await page.waitForTimeout(400);
  await page.evaluate(() => { location.hash = "#optimizer"; });
  await page.waitForTimeout(300);
  await page.selectOption("#opt-preset", "MyWeirdPreset");
  await page.waitForTimeout(200);
  const vals = {};
  for (const k of ["skill","availability","seniority","discipline"]) {
    vals[k] = await page.locator("#w-" + k).inputValue();
  }
  console.log("restored slider values:", JSON.stringify(vals));
});
