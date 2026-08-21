const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test("MGR-5 equivalent: boot normal -> check session-only -> delete records -> uncheck, no reload -> deletion IS committed, but badge never lied about it", async ({ page }) => {
  await loadApp(page);
  await loadDemoData(page);
  await page.waitForTimeout(600);
  const before = await page.evaluate(() => window.ROE.store.getState().employees.length);
  expect(before).toBeGreaterThan(10);

  await page.evaluate(() => { location.hash = "#settings"; });
  await page.waitForTimeout(150);
  await page.locator("#set-sessionOnly").check();
  await page.waitForTimeout(100);

  // Badge must be hidden right now (persistence genuinely still active - hydrated never changed).
  let badgeVisible = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
  expect(badgeVisible, "badge must stay hidden - writes are genuinely still active even though the box just got checked").toBe(false);

  await page.evaluate(() => {
    const S = window.ROE.store;
    const ids = S.getState().employees.slice(0, 5).map((e) => e.id);
    ids.forEach((id) => S.remove("employees", id));
  });
  await page.waitForTimeout(700);

  await page.locator("#set-sessionOnly").uncheck();
  await page.waitForTimeout(700);

  badgeVisible = await page.locator("#session-badge").evaluate((el) => el.classList.contains("visible"));
  expect(badgeVisible, "badge must still be hidden after unchecking too - still no reload happened, writes remain active").toBe(false);

  const inMemAfter = await page.evaluate(() => window.ROE.store.getState().employees.length);
  expect(inMemAfter).toBe(before - 5);

  await page.reload({ waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
  await page.waitForTimeout(400);
  const afterReload = await page.evaluate(() => window.ROE.store.getState().employees.length);
  console.log("MGR-5-equivalent:", JSON.stringify({ before, afterDeleteAndUncheckNoReload: inMemAfter, afterReload }));
  // Deletion is genuinely committed (documented, transparent behavior) - not a silent lie, since the
  // badge accurately signaled "still saving" the entire time.
  expect(afterReload, "deletion made while hydrated=true is real and committed - this matches the toast/hint copy, and the badge never claimed otherwise").toBe(before - 5);
});
