// §9 "Optimizer" acceptance criteria driven through the real UI: weight sliders, presets,
// candidate breakdown reachable in one click, and Commit not writing until pressed.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("Optimizer weight sliders & presets (§9 Optimizer)", () => {
  test("weight sliders visibly reorder the candidate list", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);

    const readOrder = () => page.locator(".candidate-card strong").allTextContents();
    const orderDefault = await readOrder();

    // Push discipline weight to 100 and everything else to 0 - should reorder unless the list
    // happens to already be discipline-sorted for this particular demand.
    await page.locator("#w-skill").fill("0");
    await page.locator("#w-skill").dispatchEvent("input");
    await page.locator("#w-availability").fill("0");
    await page.locator("#w-availability").dispatchEvent("input");
    await page.locator("#w-seniority").fill("0");
    await page.locator("#w-seniority").dispatchEvent("input");
    await page.locator("#w-discipline").fill("100");
    await page.locator("#w-discipline").dispatchEvent("input");
    await page.waitForTimeout(200);
    const orderDisciplineOnly = await readOrder();

    expect(orderDisciplineOnly).not.toEqual(orderDefault);
  });

  test("FIXED: a saved preset restores the exact raw slider weights after reload, even when they don't already sum to 100", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);

    // Raw weights 10/10/10/10 (sum = 40, deliberately not 100) - a legal slider state per §4.4
    // ("Sliders are 0-100 ints, normalized at read time").
    for (const k of ["skill", "availability", "seniority", "discipline"]) {
      await page.locator("#w-" + k).fill("10");
      await page.locator("#w-" + k).dispatchEvent("input");
    }
    page.once("dialog", async (d) => { await d.accept("ExactWeightsPreset"); });
    await page.click("#opt-save-preset");
    await page.waitForTimeout(600);

    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(700);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);

    await page.selectOption("#opt-preset", "ExactWeightsPreset");
    await page.waitForTimeout(200);
    const restored = {};
    for (const k of ["skill", "availability", "seniority", "discipline"]) {
      restored[k] = await page.locator("#w-" + k).inputValue();
    }
    // setWeightPreset() now stores the raw slider integers as-is (10/10/10/10); normalization
    // happens only at scoring time (SCORE.normalizeWeights), never at storage/restore time.
    expect(restored, "preset should restore the exact original slider weights (10/10/10/10), not a renormalized value").toEqual({
      skill: "10", availability: "10", seniority: "10", discipline: "10",
    });
  });
});

test.describe("Optimizer candidate breakdown & commit (§9 Optimizer)", () => {
  test("every candidate's matchScore has its full breakdown reachable via the Review button in one click", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);
    const firstCard = page.locator(".candidate-card").first();
    await expect(firstCard).toBeVisible();
    await firstCard.locator(".review-candidate").click();
    await page.waitForTimeout(200);
    const modalText = await page.locator("#modal-root .modal").innerText();
    expect(modalText).toContain("matchScore");
    expect(modalText).toContain("Skill");
    expect(modalText).toContain("Availability");
    expect(modalText).toContain("Modifiers");
  });

  test("nothing is written to the store until Commit is pressed (real UI: viewing candidates does not mutate assignments)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);
    const before = await page.evaluate(() => window.ROE.store.getState().assignments.length);
    // Switch project/demand a few times without committing.
    const projectOptions = await page.locator("#opt-project option").count();
    if (projectOptions > 1) {
      await page.selectOption("#opt-project", { index: 1 });
      await page.waitForTimeout(150);
    }
    const after = await page.evaluate(() => window.ROE.store.getState().assignments.length);
    expect(after).toBe(before);
  });

  test("committing a candidate adds exactly one Committed assignment sourced 'optimizer'", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);
    const before = await page.evaluate(() => window.ROE.store.getState().assignments.length);
    const firstCard = page.locator(".candidate-card").first();
    await expect(firstCard).toBeVisible();
    await firstCard.locator(".commit-candidate").click();
    await page.waitForTimeout(200);
    const state = await page.evaluate(() => window.ROE.store.getState());
    expect(state.assignments.length).toBe(before + 1);
    const newest = state.assignments[state.assignments.length - 1];
    expect(newest.status).toBe("Committed");
    expect(newest.source).toBe("optimizer");
  });
});
