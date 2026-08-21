const { test, expect } = require("@playwright/test");
const { loadApp } = require("../helpers/loadApp");

test.describe("ADVERSARIAL: horizonStart validation edge cases beyond the happy path", () => {
  test("a shape-valid but semantically-invalid month (2026-13, 2026-00) is NOT caught by the regex-only check", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    const input = page.locator("#set-horizonStart");
    await input.fill("2026-13");
    await input.dispatchEvent("change");
    await page.waitForTimeout(150);
    const val = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
    console.log("horizonStart after entering 2026-13:", val);
    // Documented finding, not necessarily a hard failure of the literal §9 bullet (which only
    // requires *a* validation error message to exist, not month-range correctness) - but worth
    // flagging since it lets clearly-garbage data (month 13) through as if valid.
    expect(val).not.toBe("2026-13");
  });
});
