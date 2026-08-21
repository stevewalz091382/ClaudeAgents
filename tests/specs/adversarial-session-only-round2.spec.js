// ADVERSARIAL round-2 spec, UPDATED in round 3 (fix-loop 3/3) per the Manager's reload-gated fix.
//
// Round-3 context: the Manager's MANAGER_REVIEW.md "round 2" section found that `sessionOnly` and
// `hydrated` could diverge mid-session, and initially characterized every consequence of that
// (including tests (a)/(b) below, as originally written) as a bug to be prevented outright. On
// closer analysis (documented inline in the Manager's own fix instructions, which explicitly work
// through and reverse the initial framing), the mandated fix is NOT to block writes while the
// checkbox is checked in a session that booted already-hydrated - continuing to save exactly as
// before ("reload to apply", symmetric in both directions) is declared "fine and consistent". What
// is actually mandated to be fixed:
//   1. The toggle's own onchange handler must never itself trigger a write (in either direction) -
//      only the user's own subsequent edits do, exactly as they would have without ever touching the
//      checkbox.
//   2. Real write behavior is gated SOLELY by `hydrated`, which only changes via an actual reload
//      (load()/clearAll()), so flipping the live checkbox can never itself change what happens to
//      disk this session.
//   3. The session badge and settings-panel copy must reflect what's ACTUALLY happening right now
//      (driven by `hydrated`/isPersistenceActive()), never what the checkbox currently displays.
//
// Tests (a) and (b) below are REWRITTEN to assert the corrected, intended behavior for a session
// that booted already-hydrated (normal boot): edits continue to be saved throughout, regardless of
// how the checkbox is flipped, and the badge/copy never claim otherwise. Tests (d), (e), (f) are NEW
// round-3 tests covering the symmetric, and actually-privacy-preserving, case: a session that booted
// session-only (hydrated=false) never writes anything to disk in either toggle direction, until a
// real reload. Test (g) is a new dedicated badge-honesty test spanning a full boot/toggle/reload
// cycle, closing the Manager's MGR-7 finding.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("ADVERSARIAL round 2/3: session-only toggle is reload-gated; badge/copy never lie", () => {

  test("(a, round-3 corrected) boot normal (hydrated) -> check ON -> add data -> uncheck OFF -- no reload -- edits keep saving normally the whole time, and the badge never falsely claims otherwise", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // ~40 employees now genuinely in IndexedDB, hydrated=true

    const idbBefore = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbBefore).toBeGreaterThan(0);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);

    // Turn session-only ON via the real checkbox. Per the round-3 fix, this must NOT itself write
    // anything and must NOT stop this session's saves - it only takes effect on the NEXT reload.
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(100);

    // The badge must not lie: writes are still actually active right now (hydrated is still true),
    // so the "session only - not saving" badge must stay hidden even though the box is checked.
    const badgeVisibleAfterCheck = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    expect(badgeVisibleAfterCheck, "badge must reflect the ACTUAL write-state (still hydrated/saving), not the raw checkbox value").toBe(false);

    const newId = await page.evaluate(() => {
      var id = "adversarial-r3-" + Date.now();
      window.ROE.store.upsert("employees", {
        id: id, name: "Edit made after checking ON", role: "Engineer", disciplines: [], skills: {},
        capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: []
      });
      return id;
    });
    await page.waitForTimeout(100);

    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(700); // let the normal debounce fire, same as it would have unaffected

    const idbAfterToggleOff = await page.evaluate(async () => await window.ROE.db.readAll("employees"));
    const idsAfter = idbAfterToggleOff.map(function(e){ return e.id; });
    console.log("IDB employee count after boot-normal ON->add->OFF (no reload):", idbAfterToggleOff.length, "contains new record:", idsAfter.indexOf(newId) !== -1);

    // Corrected expectation: since the session booted hydrated=true and the checkbox toggle itself
    // never changes `hydrated`, saves continue exactly as they always would have. This is the
    // Manager's own explicitly-confirmed "fine and consistent" outcome, NOT a privacy leak, because
    // the badge/copy never claimed otherwise at any point (verified above and in test (g)).
    expect(idsAfter.indexOf(newId), "edits made during an already-hydrated session must keep saving normally regardless of the checkbox, per the round-3 fix").not.toBe(-1);
  });

  test("(b, round-3 corrected) boot normal from an empty app -> check ON -> add data -> uncheck OFF -> reload: the edit legitimately survives, because the session was hydrated throughout", async ({ page }) => {
    await loadApp(page);
    // Do NOT load demo data - start from a genuinely empty app/IndexedDB. A fresh boot with no
    // stored session-only preference still hydrates normally (hydrated=true).
    const idbEmptyAtStart = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbEmptyAtStart).toBe(0);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(100);

    await page.evaluate(() => {
      window.ROE.store.upsert("employees", {
        id: "ephemeral-r3-1", name: "Added after checking ON, empty app", role: "Engineer", disciplines: [], skills: {},
        capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: []
      });
    });
    await page.waitForTimeout(100);
    const inMemoryWhileOn = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(inMemoryWhileOn).toBe(1); // sanity: the add worked in memory

    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(700); // let the normal debounce complete

    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const employeesAfterReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    const idbAfterReload = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    console.log("after boot-normal ON(empty)->add->OFF->reload: in-memory =", employeesAfterReload, "| IDB =", idbAfterReload);

    // Corrected expectation: the session booted hydrated=true, so the edit was a normal save the
    // whole time; the reload happens with sessionOnly now written OFF as a preference, so the
    // reloaded app hydrates normally from disk and finds the record it legitimately saved earlier.
    expect(employeesAfterReload, "the edit was made during an already-hydrated session, so it legitimately persists").toBe(1);
    expect(idbAfterReload, "IndexedDB must contain the record that was actually saved during the hydrated session").toBe(1);
  });

  test("(c) repeat stability: the fixed ON->reload->OFF->reload sequence preserves pre-existing data across 3 repeated attempts", async ({ page }) => {
    for (let i = 0; i < 3; i++) {
      await loadApp(page);
      await loadDemoData(page);
      await page.waitForTimeout(600);

      await page.evaluate(() => { location.hash = "#settings"; });
      await page.waitForTimeout(150);
      await page.locator("#set-sessionOnly").check();
      await page.waitForTimeout(200);

      await page.reload({ waitUntil: "load" });
      await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
      await page.waitForTimeout(400);

      await page.evaluate(() => { location.hash = "#settings"; });
      await page.waitForTimeout(150);
      await page.locator("#set-sessionOnly").uncheck();
      await page.waitForTimeout(700);

      await page.reload({ waitUntil: "load" });
      await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
      await page.waitForTimeout(500);

      const employeesAfter = await page.evaluate(() => window.ROE.store.getState().employees.length);
      console.log("iteration", i, "employees after full ON/reload/OFF/reload cycle:", employeesAfter);
      expect(employeesAfter, "iteration " + i + ": data must survive the full toggle cycle").toBeGreaterThan(0);

      // Clean slate for next iteration.
      page.once("dialog", async (dialog) => { await dialog.accept("CLEAR"); });
      await page.click("#btn-clear-all");
      await page.waitForTimeout(400);
    }
  });

  test("(d, NEW round-3 - Manager repro (a) generalized) new data is NOT written until reload, in BOTH toggle directions, whenever the session actually booted session-only (hydrated=false)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // 40 employees genuinely persisted, hydrated=true

    const idbBefore = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbBefore).toBeGreaterThan(0);

    // Turn session-only ON and reload, so the NEXT boot actually starts session-only: hydrated=false.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(150);
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(400);

    const memoryAfterSessionOnlyReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(memoryAfterSessionOnlyReload, "session-only reload must start with empty in-memory state").toBe(0);

    // Direction 1: checkbox LEFT CHECKED (still ON). Add data while hydrated=false.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.evaluate(() => {
      window.ROE.store.upsert("employees", {
        id: "d1-still-checked", name: "Added while still checked, hydrated=false", role: "Engineer",
        disciplines: [], skills: {}, capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: []
      });
    });
    await page.waitForTimeout(700);
    let idbCount = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbCount, "direction 1 (checkbox still checked): adding data while hydrated=false must not write to IndexedDB").toBe(idbBefore);

    // Direction 2: UNCHECK the box (still no reload). Add MORE data while still hydrated=false.
    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(150);
    await page.evaluate(() => {
      window.ROE.store.upsert("employees", {
        id: "d2-just-unchecked", name: "Added right after unchecking, still hydrated=false", role: "Engineer",
        disciplines: [], skills: {}, capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: []
      });
    });
    await page.waitForTimeout(700);
    idbCount = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbCount, "direction 2 (checkbox just unchecked, no reload yet): adding data must STILL not write to IndexedDB, because hydrated is still false").toBe(idbBefore);

    // Now actually reload (preference is OFF, so this reload rehydrates from disk normally).
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const finalMemory = await page.evaluate(() => window.ROE.store.getState().employees.map(function(e){ return e.id; }));
    console.log("final employee count after real reload:", finalMemory.length);
    expect(finalMemory.length, "the original disk data must come back intact").toBe(idbBefore);
    expect(finalMemory.indexOf("d1-still-checked"), "ephemeral record from direction 1 must never have reached disk").toBe(-1);
    expect(finalMemory.indexOf("d2-just-unchecked"), "ephemeral record from direction 2 must never have reached disk").toBe(-1);
  });

  test("(e, NEW round-3 - Manager repro (b) generalized) deletions made while hydrated=false are NOT committed in either toggle direction; original disk data survives untouched until reload", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // e.g. 40 employees genuinely persisted, hydrated=true
    const idbBefore = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbBefore).toBeGreaterThan(0);

    // Turn session-only ON and reload so the app actually boots session-only: hydrated=false, memory
    // starts empty (disk untouched, still has the original records).
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(150);
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(400);

    // Populate in-memory-only data to delete from (loadDemoData while hydrated=false never writes,
    // since scheduleSave/persist are gated solely on `hydrated`).
    await page.evaluate(() => { window.ROE.store.loadDemoData(); });
    await page.waitForTimeout(300);
    const inMemoryCount = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(inMemoryCount).toBeGreaterThan(0);

    // Delete some records while the box is still checked ON.
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.evaluate(() => {
      var ids = window.ROE.store.getState().employees.slice(0, 20).map(function(e){ return e.id; });
      ids.forEach(function(id){ window.ROE.store.remove("employees", id); });
    });
    await page.waitForTimeout(500);
    let idbCount = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbCount, "deletions performed while hydrated=false (box still checked) must not touch IndexedDB").toBe(idbBefore);

    // Uncheck the box (still no reload) and delete a few more.
    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(150);
    await page.evaluate(() => {
      var ids = window.ROE.store.getState().employees.slice(0, 5).map(function(e){ return e.id; });
      ids.forEach(function(id){ window.ROE.store.remove("employees", id); });
    });
    await page.waitForTimeout(700);
    idbCount = await page.evaluate(async () => (await window.ROE.db.readAll("employees")).length);
    expect(idbCount, "deletions performed right after unchecking, still hydrated=false, must STILL not touch IndexedDB").toBe(idbBefore);

    // Reload for real: preference is OFF, so this rehydrates normally from disk.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const finalCount = await page.evaluate(() => window.ROE.store.getState().employees.length);
    console.log("employee count after real reload following in-session (never-committed) deletions:", finalCount);
    expect(finalCount, "none of the in-memory-only deletions may have reached disk; the original data must be fully intact").toBe(idbBefore);
  });

  test("(g, NEW round-3 - closes Manager MGR-7) the session badge accurately reflects the ACTUAL write-state at every point of a full boot/toggle/reload/toggle/reload cycle, never the raw checkbox value", async ({ page }) => {
    async function badgeVisible(){
      return await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
    }

    await loadApp(page);
    await loadDemoData(page);
    await page.waitForTimeout(600); // hydrated=true, writes genuinely active

    expect(await badgeVisible(), "boot normal: writes are active, badge must be hidden").toBe(false);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").check();
    await page.waitForTimeout(150);
    // Still hydrated=true (no reload yet): writes are STILL active this session, so the badge must
    // NOT flip to "session only" just because the checkbox is now checked.
    expect(await badgeVisible(), "checked ON but not yet reloaded: still hydrated/writing, badge must stay hidden").toBe(false);
    const stillWritten = await page.evaluate(() => {
      var id = "g-still-writing-" + Date.now();
      window.ROE.store.upsert("employees", { id: id, name: "g-probe-1", role: "Engineer", disciplines: [], skills: {}, capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: [] });
      return id;
    });
    await page.waitForTimeout(700);
    let onDisk = await page.evaluate(async (id) => (await window.ROE.db.readAll("employees")).some(function(e){ return e.id === id; }), stillWritten);
    expect(onDisk, "the badge's claim that writes are active must be true: the edit made while badge was hidden must actually be on disk").toBe(true);

    // Now actually reload: preference is ON, so this boots session-only, hydrated=false.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(400);
    expect(await badgeVisible(), "after a real session-only reload: writes are genuinely inactive, badge must be visible").toBe(true);

    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(150);
    await page.locator("#set-sessionOnly").uncheck();
    await page.waitForTimeout(150);
    // Still hydrated=false (no reload yet): writes are STILL inactive, so the badge must NOT
    // disappear just because the checkbox is now unchecked. This is the exact MGR-7 fix.
    expect(await badgeVisible(), "unchecked OFF but not yet reloaded: still not hydrated/not writing, badge must stay visible").toBe(true);
    const notWritten = await page.evaluate(() => {
      var id = "g-not-writing-" + Date.now();
      window.ROE.store.upsert("employees", { id: id, name: "g-probe-2", role: "Engineer", disciplines: [], skills: {}, capacityHoursPerWeek: 40, targetUtilizationPct: 85, allocations: [] });
      return id;
    });
    await page.waitForTimeout(700);
    onDisk = await page.evaluate(async (id) => (await window.ROE.db.readAll("employees")).some(function(e){ return e.id === id; }), notWritten);
    expect(onDisk, "the badge's claim that writes are inactive must be true: the edit made while badge was visible must NOT be on disk").toBe(false);

    // Reload again for real: preference is now OFF, so this rehydrates normally, hydrated=true.
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(400);
    expect(await badgeVisible(), "after the real reload resuming normal mode: writes are active again, badge must be hidden").toBe(false);
  });
});
