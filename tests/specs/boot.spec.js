// §9 "Global" acceptance criteria: boots from file:// with no uncaught JS exceptions, and degrades
// gracefully with both CDNs blocked (the actual state of this sandbox - see TEST_REPORT.md).
const { test, expect } = require("@playwright/test");
const { loadApp } = require("../helpers/loadApp");

test("boots from file:// with no uncaught JS exceptions, ROE namespace present, vendor banner shown when CDNs are blocked", async ({ page }) => {
  const pageErrors = [];
  const consoleErrors = [];
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  page.on("console", (msg) => { if (msg.type() === "error") consoleErrors.push(msg.text()); });

  await loadApp(page);
  await page.waitForTimeout(1000);

  expect(pageErrors, "no uncaught JS exceptions on boot").toEqual([]);

  const chartPresent = await page.evaluate(() => !!window.Chart);
  const xlsxPresent = await page.evaluate(() => !!window.XLSX);
  const bannerVisible = await page.locator("#vendor-banner").isVisible();
  const bannerText = bannerVisible ? await page.locator("#vendor-banner").innerText() : "";

  // This environment's outbound proxy blocks cdn.jsdelivr.net (confirmed via
  // curl "$HTTPS_PROXY/__agentproxy/status", same failure the Coder reported in their own
  // sandbox), so both vendor libraries are expected to be absent here.
  if (!chartPresent || !xlsxPresent) {
    expect(bannerVisible, "vendor banner must explain the missing library, not fail silently").toBe(true);
    expect(bannerText.length).toBeGreaterThan(0);
  }

  const roePresent = await page.evaluate(() => !!(window.ROE && window.ROE.store && window.ROE.calc));
  expect(roePresent).toBe(true);

  // Console "error"-level entries from blocked network resources are expected here and are not JS
  // exceptions; only pageerror (uncaught exceptions) is the acceptance-relevant signal.
  console.log("console error-level entries (network noise expected, not JS exceptions):", JSON.stringify(consoleErrors));
});

test("grep-equivalent: no fetch/XHR happens at boot other than the two CDN <script> tags", async ({ page }) => {
  const requests = [];
  page.on("request", (req) => requests.push(req.url()));
  await loadApp(page);
  await page.waitForTimeout(1000);
  const nonCdnNonFile = requests.filter((u) => !u.startsWith("file://") && !u.includes("cdn.jsdelivr.net"));
  expect(nonCdnNonFile, "unexpected network requests at boot: " + JSON.stringify(nonCdnNonFile)).toEqual([]);
});
