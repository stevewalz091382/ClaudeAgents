const { test, expect } = require("@playwright/test");
const { loadApp } = require("../helpers/loadApp");

test.describe("ADVERSARIAL round 2: more horizonStart edge cases", () => {
  const cases = [
    { input: "2026-00", label: "month 00" },
    { input: "0000-01", label: "year 0000 (shape-valid, arguably nonsensical year)" },
    { input: "2026-1", label: "single-digit month, wrong shape" },
    { input: "2026-AA", label: "non-numeric month" },
    { input: "9999-12", label: "far-future year (shape+range valid, should be accepted)" },
    { input: "2026-99", label: "wildly out of range month" },
  ];

  for (const c of cases) {
    test(`horizonStart "${c.input}" (${c.label})`, async ({ page }) => {
      await loadApp(page);
      await page.evaluate(() => { location.hash = "#settings"; });
      await page.waitForTimeout(200);
      const before = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
      const input = page.locator("#set-horizonStart");
      await input.fill(c.input);
      await input.dispatchEvent("change");
      await page.waitForTimeout(150);
      const after = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
      console.log(`horizonStart "${c.input}" -> stored as "${after}" (was "${before}")`);
    });
  }
});
