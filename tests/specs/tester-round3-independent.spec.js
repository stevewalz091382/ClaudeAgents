// INDEPENDENT round-3 re-verification, written by the Tester without reusing the Coder's spec code.
// Reads IndexedDB directly via raw indexedDB.open() rather than trusting ROE.store's own reporting,
// and re-implements the Manager's exact three repro scenarios (a/b/c) from MANAGER_REVIEW.md.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

// Raw IndexedDB read, independent of ROE.db, so a bug in ROE.db's own reporting can't hide a real
// on-disk discrepancy from us.
async function rawEmployeeCount(page) {
  return page.evaluate(() => {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open("roe");
      req.onerror = () => reject(req.error);
      req.onsuccess = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains("employees")) { db.close(); resolve(0); return; }
        const tx = db.transaction(["employees"], "readonly");
        const store = tx.objectStore("employees");
        const countReq = store.count();
        countReq.onsuccess = () => { const c = countReq.result; db.close(); resolve(c); };
        countReq.onerror = () => { db.close(); reject(countReq.error); };
      };
    });
  });
}

test.describe("TESTER round 3 independent verification (Manager repro a/b/c)", () => {
  test("MGR-repro(a): boot normal (hydrated) -> check session-only ON -> add data -> uncheck OFF, no reload -> check disk directly", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    const before = await rawEmployeeCount(page);
    expect(before).toBeGreaterThan(0);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(100);

    // Add a new employee via the real store API while the checkbox is checked but unreloaded.
    await page.evaluate(() => {
      window.ROE.store.upsert("employees", { id: "mgr-a-new-emp", name: "MGR Repro A", role: "Engineer", homeTeam: "T1" });
    });
    await page.waitForTimeout(700); // clear the 400ms debounce

    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(700);

    const afterCount = await rawEmployeeCount(page);
    const afterHasNew = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const req = indexedDB.open("roe");
        req.onsuccess = () => {
          const db = req.result;
          const tx = db.transaction(["employees"], "readonly");
          const g = tx.objectStore("employees").get("mgr-a-new-emp");
          g.onsuccess = () => { db.close(); resolve(!!g.result); };
        };
      });
    });
    console.log("MGR-A-repro:", JSON.stringify({ before, afterCount, afterHasNew }));
    // Documented (by design) behavior in round 3: since `hydrated` was never false in this
    // session (no reload occurred), writes are unaffected by the checkbox in either direction.
    // This assertion documents that reality rather than asserting the old (impossible-without-reload)
    // "nothing written" promise.
    expect(afterHasNew, "round-3 design: without an actual reload, hydrated stays true and writes keep happening regardless of the checkbox - this must match the toast/hint copy, not silently diverge from it").toBe(true);
  });

  test("MGR-repro(a2): TRUE session-only window (post session-only reload) -> add data -> toggle OFF, no reload -> check disk", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    const baseline = await rawEmployeeCount(page);
    expect(baseline).toBeGreaterThan(0);

    // Turn session-only ON and reload so hydrated actually becomes false.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(300);

    const inMemAfterSessionReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(inMemAfterSessionReload, "session-only reload should start with an empty in-memory slate").toBe(0);

    // Now, while hydrated=false, add data.
    await page.evaluate(() => {
      window.ROE.store.upsert("employees", { id: "mgr-a2-new-emp", name: "MGR Repro A2", role: "Engineer", homeTeam: "T1" });
    });
    await page.waitForTimeout(700);

    // Uncheck the box WITHOUT reloading.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(700);

    const diskCountNoReload = await rawEmployeeCount(page);
    console.log("MGR-A2-repro (true session-only window):", JSON.stringify({ baseline, diskCountNoReload }));
    // The real bug-fix claim under test: while genuinely in the un-hydrated window, the new record
    // must NOT appear on disk, regardless of toggling the checkbox off, until an actual reload.
    expect(diskCountNoReload, "disk count must be unchanged (baseline) while hydrated=false, even after unchecking session-only without reload").toBe(baseline);
  });

  test("MGR-repro(b): true session-only window -> DELETE existing records -> toggle OFF, no reload -> check disk", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    const baseline = await rawEmployeeCount(page);
    expect(baseline).toBeGreaterThan(10);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(300);

    // In-memory is empty (session-only skip-load). To simulate "the user had data in memory and
    // deleted some of it" in the adversarial sense the Manager meant (data present in this
    // session, then deleted), seed in-memory state directly (as if imported/added this session),
    // then delete half of it, all while hydrated=false.
    await page.evaluate(() => {
      const S = window.ROE.store;
      for (let i = 0; i < 10; i++) {
        S.upsert("employees", { id: "mgr-b-emp-" + i, name: "E" + i, role: "Engineer", homeTeam: "T1" });
      }
    });
    await page.waitForTimeout(700);
    await page.evaluate(() => {
      const S = window.ROE.store;
      for (let i = 0; i < 5; i++) S.remove("employees", "mgr-b-emp-" + i);
    });
    await page.waitForTimeout(700);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(700);

    const diskCountNoReload = await rawEmployeeCount(page);
    console.log("MGR-B-repro:", JSON.stringify({ baseline, diskCountNoReload }));
    expect(diskCountNoReload, "the original 40+ demo records must still be intact on disk - none of the session-only add/delete churn should have touched disk before a reload").toBe(baseline);

    // Now actually reload and confirm original data (not the session churn) is what comes back.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);
    const finalCount = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(finalCount, "reload after uncheck should resume normal hydration and restore exactly the pre-session-only baseline").toBe(baseline);
  });

  test("MGR-repro(c): session-only reload -> toggle OFF -> check badge vs actual write-state IMMEDIATELY, no reload", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    const baseline = await rawEmployeeCount(page);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(300);

    // Do some "session only" work.
    await page.evaluate(() => {
      window.ROE.store.upsert("employees", { id: "mgr-c-emp", name: "MGR C", role: "Engineer", homeTeam: "T1" });
    });
    await page.waitForTimeout(700);

    // Uncheck without reloading.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(200);

    const badgeVisible = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    const actuallyWriting = await page.evaluate(() => window.ROE.store.isPersistenceActive());
    const diskCount = await rawEmployeeCount(page);
    console.log("MGR-C-repro:", JSON.stringify({ badgeVisible, actuallyWriting, diskCount, baseline }));

    // Badge visible == true means "session only / not saving". It must agree with reality:
    // if writes are NOT actually active (actuallyWriting === false), the badge MUST be visible,
    // never hidden (that was the round-2 lie). Since we just unchecked without reload,
    // actuallyWriting should still be false (hydrated didn't change), so badge must still show.
    expect(actuallyWriting, "hydrated must still be false immediately after unchecking, pre-reload").toBe(false);
    expect(badgeVisible, "badge must still be visible (truthfully claiming not-saving) even though the checkbox now reads unchecked, since no reload happened yet").toBe(true);
    expect(diskCount, "no write should have escaped to disk during this whole window").toBe(baseline);
  });

  test("REGRESSION CHECK: normal (non-session-only) persistence path is completely unaffected by the hydrated-gating change", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600);
    const afterDemo = await rawEmployeeCount(page);
    expect(afterDemo).toBeGreaterThan(0);

    // Add, edit, delete, all in the plain default (non-session-only) mode, verify each hits disk.
    await page.evaluate(() => {
      window.ROE.store.upsert("employees", { id: "reg-emp-1", name: "Reg One", role: "Engineer", homeTeam: "T1" });
    });
    await page.waitForTimeout(700);
    expect(await rawEmployeeCount(page)).toBe(afterDemo + 1);

    await page.evaluate(() => { window.ROE.store.remove("employees", "reg-emp-1"); });
    await page.waitForTimeout(700);
    expect(await rawEmployeeCount(page)).toBe(afterDemo);

    // Reload and confirm hydrated=true, isPersistenceActive() true, badge hidden - the ordinary path.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(400);
    const activeAfterReload = await page.evaluate(() => window.ROE.store.isPersistenceActive());
    const badgeVisibleAfterReload = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    const countAfterReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(activeAfterReload, "default/normal path: hydrated must be true after an ordinary reload").toBe(true);
    expect(badgeVisibleAfterReload, "default/normal path: session badge must be hidden (not falsely claiming session-only)").toBe(false);
    expect(countAfterReload).toBe(afterDemo);
  });

  test("REGRESSION CHECK: brand-new user, never touches the checkbox at all, first-ever boot persists normally", async ({ page }) => {
    // Each Playwright test gets a fresh, isolated browser context/storage by default, so this is
    // already a brand-new IndexedDB with no prior "roe" database - no explicit deletion needed.
    await loadApp(page);
    await page.waitForTimeout(300);
    const activeFirstBoot = await page.evaluate(() => window.ROE.store.isPersistenceActive());
    expect(activeFirstBoot, "a first-ever boot with an empty/no IndexedDB (never touched sessionOnly) must still be hydrated=true so ordinary users get persistence by default").toBe(true);

    await loadDemoData(page);
    await page.waitForTimeout(700);
    const disk = await rawEmployeeCount(page);
    expect(disk).toBeGreaterThan(0);
  });
});
