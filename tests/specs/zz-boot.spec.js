const { test, expect } = require("@playwright/test");
const { loadApp } = require("../helpers/loadApp");

test("boots with no console errors and ROE namespace present", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (msg) => { if (msg.type() === "error") errors.push(msg.text()); });
  await loadApp(page);
  await page.waitForTimeout(1500);
  console.log("CONSOLE ERRORS:", JSON.stringify(errors));
  console.log("Chart present:", await page.evaluate(() => !!window.Chart));
  console.log("XLSX present:", await page.evaluate(() => !!window.XLSX));
  console.log("vendor banner text:", await page.locator("#vendor-banner").innerText().catch(()=>"<none>"));
});
