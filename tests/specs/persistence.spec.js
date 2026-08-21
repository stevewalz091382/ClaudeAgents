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

  test("CONTROL: session-only turned on BEFORE any data ever existed -> load demo -> reload loses everything", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await loadDemoData(page);
    await page.waitForTimeout(600);
    const before = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(before).toBeGreaterThan(0);
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const after = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(after).toBe(0);
  });

  test("BUG: toggling session-only ON, via the real settings checkbox, *after* data was already persisted does NOT lose it on reload", async ({ page }) => {
    // Realistic sequence: load demo data (auto-persists per the 400ms debounce), THEN flip the
    // real "Session only" checkbox in Data & Settings. Per §9: "Session-only mode ON -> reload
    // loses everything and the badge was visible the whole time."
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // demo data is now persisted to IndexedDB
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(200);

    const badgeVisibleBeforeReload = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    expect(badgeVisibleBeforeReload, "badge should be visible immediately after enabling session-only via the real checkbox").toBe(true);

    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const employeesAfter = await page.evaluate(() => window.ROE.store.getState().employees.length);
    // This is the acceptance criterion: reload must lose everything. It does not - the previously
    // persisted 40 demo employees come back, because setSessionOnly() only prevents *future*
    // writes; it never clears data already sitting in IndexedDB from before the toggle, and
    // load() unconditionally reads from IndexedDB on boot regardless of the in-memory sessionOnly
    // flag at the moment of toggling (the persisted settings record itself is also never updated
    // to sessionOnly:true, since scheduleSave() is skipped once sessionOnly is true).
    expect(employeesAfter, "session-only reload must lose everything per §9, but stale pre-toggle IndexedDB data reappears").toBe(0);
  });

  test("Clear all data: wrong confirmation text does not clear; 'CLEAR' clears every IndexedDB object store", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);

    page.once("dialog", async (dialog) => { await dialog.accept("not clear"); });
    await page.click("#btn-clear-all");
    await page.waitForTimeout(300);
    const stillHasData = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(stillHasData, "typing the wrong confirmation text must NOT clear data").toBeGreaterThan(0);

    page.once("dialog", async (dialog) => { await dialog.accept("CLEAR"); });
    await page.click("#btn-clear-all");
    await page.waitForTimeout(400);

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

  test("Clear all data is also reachable and functions from Data & Settings (#btn-clear-all-2)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    page.once("dialog", async (dialog) => { await dialog.accept("CLEAR"); });
    const btn = page.locator("#btn-clear-all-2");
    await expect(btn).toBeVisible();
    await btn.click();
    await page.waitForTimeout(400);
    const afterEmployees = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(afterEmployees).toBe(0);
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
          out[n] = await DB.getRecord(n, n === "settings" ? "app" : "schemaVersion").catch(() => null);
        }
      }
      return out;
    });
    const serialized = JSON.stringify(dump);
    expect(serialized.includes(SECRET_TOKEN)).toBe(false);
  });

  test("config (minus token) survives reload; the token does not (§9 API)", async ({ page }) => {
    await loadApp(page);
    const SECRET_TOKEN = "reload-should-drop-this-token";
    await page.evaluate((tok) => {
      window.ROE.api.setToken(tok);
      window.ROE.store.setSettings({ api: Object.assign({}, window.ROE.store.getState().settings.api, { authMode: "bearer", baseUrl: "https://persisted.example.test" }) });
    }, SECRET_TOKEN);
    await page.waitForTimeout(600);
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const result = await page.evaluate(() => ({
      baseUrl: window.ROE.store.getState().settings.api.baseUrl,
      hasToken: window.ROE.api.hasToken(),
    }));
    expect(result.baseUrl).toBe("https://persisted.example.test");
    expect(result.hasToken).toBe(false);
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

  test("NOTE: STORE.subscribe()/notify() has no subscribers in ROE.ui - programmatic store mutations do not refresh the UI", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(300);
    const before = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    await page.evaluate(() => window.ROE.store.setSessionOnly(true)); // bypasses the UI entirely
    await page.waitForTimeout(200);
    const afterProgrammatic = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    expect(before).toBe(false);
    // Documents current behavior: the badge does NOT update from a raw store mutation because no
    // UI code ever calls STORE.subscribe(...). Every render is driven by explicit calls in event
    // handlers, not by the store's own pub/sub. Not a §9 acceptance-criterion failure by itself
    // (the real checkbox does trigger updateSessionBadge()), but it means STORE.subscribe/notify
    // (called out by name in BUILD_PLAN.md §2.2) is dead code, and any future code path that
    // mutates the store without going through a hand-wired UI handler will render a stale badge.
    expect(afterProgrammatic).toBe(false);
  });
});
