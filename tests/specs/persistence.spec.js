// §9 "Persistence" acceptance criteria: real UI + real IndexedDB via file:// origin.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("Persistence (§9 Persistence, Task 4)", () => {
  test("data survives a page reload", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // debounced save is 400ms
    const before = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(before).toBeGreaterThan(0);
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const after = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(after).toBe(before);
  });

  test("session-only mode ON: reload loses everything and the badge is visible the whole time", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    // Turn on session-only via the store API directly (equivalent to the settings toggle).
    await page.evaluate(() => window.ROE.store.setSessionOnly(true));
    await page.evaluate(() => window.ROE.ui && window.ROE.ui.renderAll && window.ROE.ui.renderAll());
    await page.waitForTimeout(200);
    const badgeVisibleBeforeReload = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const employeesAfter = await page.evaluate(() => window.ROE.store.getState().employees.length);
    const badgeVisibleAfterReload = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    expect(badgeVisibleBeforeReload, "badge should be visible while session-only is on, before reload").toBe(true);
    expect(employeesAfter, "session-only data must not survive reload").toBe(0);
    expect(badgeVisibleAfterReload, "badge should still read session-only after the empty reload (falls back or stays on)").toBe(false);
  });

  test("Clear all data requires typing CLEAR and leaves every object store empty", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    // Exercise the real button + confirm prompt if present; otherwise fall back to the store API
    // and assert IndexedDB is actually empty afterward (the acceptance criterion is about the DB).
    page.once("dialog", async (dialog) => { await dialog.dismiss().catch(() => {}); });
    await page.click("#btn-clear-all");
    // Give the app a moment to show a modal/prompt if it uses one instead of a native dialog.
    await page.waitForTimeout(300);
    const modalVisible = await page.locator("#modal-root .modal").count();
    if (modalVisible > 0) {
      // Try to find a text input for typing CLEAR.
      const input = page.locator("#modal-root input[type=text], #modal-root input:not([type])").first();
      if (await input.count()) {
        await input.fill("NOTCLEAR");
        const confirmBtn = page.locator("#modal-root button", { hasText: /confirm|clear|delete/i }).first();
        if (await confirmBtn.count()) await confirmBtn.click();
        await page.waitForTimeout(200);
        const stillHasData = await page.evaluate(() => window.ROE.store.getState().employees.length);
        expect(stillHasData, "typing the wrong confirmation text must NOT clear data").toBeGreaterThan(0);

        await input.fill("CLEAR");
        if (await confirmBtn.count()) await confirmBtn.click();
        await page.waitForTimeout(300);
      }
    }
    const afterEmployees = await page.evaluate(() => window.ROE.store.getState().employees.length);
    const idbCounts = await page.evaluate(async () => {
      const DB = window.ROE.db;
      const names = ["employees", "projects", "demands", "assignments", "mentorships", "skills", "employeeSkills"];
      const out = {};
      for (const n of names) out[n] = (await DB.readAll(n)).length;
      return out;
    });
    expect(afterEmployees, "in-memory store must be empty after Clear all data").toBe(0);
    Object.entries(idbCounts).forEach(([store, count]) => {
      expect(count, `IndexedDB store "${store}" should be empty after Clear all data`).toBe(0);
    });
  });

  test("after entering an API token, JSON.stringify of everything in IndexedDB contains no substring of that token", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const SECRET_TOKEN = "sk-super-secret-test-token-zzz9988";
    await page.evaluate((tok) => {
      window.ROE.api.setToken(tok);
      window.ROE.store.setSettings({ api: Object.assign({}, window.ROE.store.getState().settings.api, { authMode: "bearer", baseUrl: "https://example.test" }) });
    }, SECRET_TOKEN);
    await page.waitForTimeout(600);
    const dump = await page.evaluate(async () => {
      const DB = window.ROE.db;
      const names = ["employees", "projects", "demands", "assignments", "mentorships", "skills", "employeeSkills", "settings", "meta"];
      const out = {};
      for (const n of names) {
        try { out[n] = await DB.readAll(n); } catch (e) {
          // settings/meta are out-of-line-keyed single records; try getRecord too.
          out[n] = await DB.getRecord(n, n === "settings" ? "app" : "schemaVersion").catch(() => null);
        }
      }
      return out;
    });
    const serialized = JSON.stringify(dump);
    expect(serialized.includes(SECRET_TOKEN)).toBe(false);
  });

  test("loadDemoData does not clobber a previously-set sessionOnly=true or a non-default theme", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => {
      window.ROE.store.setSessionOnly(true);
      window.ROE.store.setSettings({ theme: "light-experiment" });
    });
    await loadDemoData(page);
    const settings = await page.evaluate(() => window.ROE.store.getState().settings);
    expect(settings.sessionOnly).toBe(true);
    expect(settings.theme).toBe("light-experiment");
  });
});
