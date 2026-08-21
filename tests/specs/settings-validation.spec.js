// Bundled LOW fix: horizonStart had no input validation (Manager stored the literal string
// "not-a-month" through the real settings input with no rejection). This spec drives the real
// #set-horizonStart input in Data & Settings and confirms invalid input is rejected with a visible
// inline error, not silently accepted.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("horizonStart input validation (bundled LOW fix)", () => {
  test("an invalid horizonStart value is rejected with a visible inline error and does not change settings", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);

    const before = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);

    await page.locator("#set-horizonStart").fill("not-a-month");
    await page.locator("#set-horizonStart").dispatchEvent("change");
    await page.waitForTimeout(150);

    const after = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
    expect(after, "an invalid horizonStart must not be stored").toBe(before);

    const errorVisible = await page.locator("#horizonStart-error").isVisible();
    expect(errorVisible, "an inline error must be shown for invalid horizonStart input").toBe(true);

    const inputValue = await page.locator("#set-horizonStart").inputValue();
    expect(inputValue, "the input should revert to the last valid value, not keep the rejected string").toBe(before);
  });

  test("a valid YYYY-MM horizonStart value is accepted and persists", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);

    await page.locator("#set-horizonStart").fill("2027-03");
    await page.locator("#set-horizonStart").dispatchEvent("change");
    await page.waitForTimeout(150);

    const after = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
    expect(after).toBe("2027-03");
    const errorVisible = await page.locator("#horizonStart-error").isVisible();
    expect(errorVisible).toBe(false);
  });
});
