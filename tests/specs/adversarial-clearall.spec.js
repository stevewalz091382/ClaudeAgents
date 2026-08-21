const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("ADVERSARIAL: does 'Clear all data' truly leave every IndexedDB object store empty?", () => {
  test("after Clear all data (typing CLEAR), the 'settings' store must be literally empty per §9 ('leaves every object store empty')", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);

    page.once("dialog", async (dialog) => { await dialog.accept("CLEAR"); });
    await page.click("#btn-clear-all");
    await page.waitForTimeout(400);

    const settingsStoreContents = await page.evaluate(async () => {
      return await window.ROE.db.readAll("settings");
    });
    console.log("settings store contents after Clear all data:", JSON.stringify(settingsStoreContents));
    expect(settingsStoreContents.length, "§9: 'Clear all data' ... 'leaves every object store empty' - the settings store now re-writes a 'prefs' record immediately after clearing").toBe(0);
  });
});
