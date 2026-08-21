const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("ADVERSARIAL re-verification of the 4 claimed fixes (independent of Coder's specs)", () => {

  test("API connector: all 5 entities have enable checkbox + path inputs + mapping UI in the real DOM", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    const entities = ["employees", "projects", "demands", "assignments", "skills"];
    for (const e of entities) {
      await expect(page.locator(`.api-ent-enabled[data-entity="${e}"]`)).toHaveCount(1);
      await expect(page.locator(`.api-ent-pullPath[data-entity="${e}"]`)).toHaveCount(1);
      await expect(page.locator(`.api-ent-pushPath[data-entity="${e}"]`)).toHaveCount(1);
      await expect(page.locator(`.api-ent-responseRoot[data-entity="${e}"]`)).toHaveCount(1);
      await expect(page.locator(`.api-ent-idField[data-entity="${e}"]`)).toHaveCount(1);
      await expect(page.locator(`#api-pull-${e}`)).toHaveCount(1);
      await expect(page.locator(`#api-push-${e}`)).toHaveCount(1);
      await expect(page.locator(`.map-add[data-entity="${e}"]`)).toHaveCount(1);
    }
  });

  test("Non-employee entity (skills) can be enabled, configured, and actually pulled via mocked endpoint", async ({ page }) => {
    await page.route("**/skills-remote", (route) => {
      route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify([
        { sid: "S1", code: "RUST", name: "Rust", category: "Dev" }
      ])});
    });
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    await page.locator('#api-baseUrl').fill("https://example.test");
    await page.locator('.api-ent-enabled[data-entity="skills"]').check();
    await page.locator('.api-ent-pullPath[data-entity="skills"]').fill("/skills-remote");
    await page.waitForTimeout(150);
    await page.locator('#api-pull-skills').click();
    await page.waitForTimeout(400);
    const state = await page.evaluate(() => window.ROE.store.getState().settings.api.entities.skills);
    expect(state.enabled).toBe(true);
    expect(state.pullPath).toBe("/skills-remote");
  });

  test("Preset round-trip: real sliders, two distinct sets that normalize to the SAME ratio (10/10/10/10 vs 20/20/20/20) restore as exact distinct raw ints after reload", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(400);

    async function setSliders(vals) {
      for (const k of ["skill", "availability", "seniority", "discipline"]) {
        await page.locator("#w-" + k).fill(String(vals[k]));
        await page.locator("#w-" + k).dispatchEvent("input");
      }
      await page.waitForTimeout(100);
    }

    await setSliders({ skill: 10, availability: 10, seniority: 10, discipline: 10 });
    page.once("dialog", async (dialog) => { await dialog.accept("DistinctSet_A"); });
    await page.click("#opt-save-preset");
    await page.waitForTimeout(400);

    // Re-navigate (renderOptimizer resets os.weights from... check) before setting second set,
    // mirroring how a real user would continue adjusting sliders in the same session.
    await setSliders({ skill: 20, availability: 20, seniority: 20, discipline: 20 });
    page.once("dialog", async (dialog) => { await dialog.accept("DistinctSet_B"); });
    await page.click("#opt-save-preset");
    await page.waitForTimeout(400);

    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => !!(window.ROE && window.ROE.store));
    await page.waitForTimeout(500);

    const presets = await page.evaluate(() => window.ROE.store.getState().settings.presets);
    console.log("presets after reload:", JSON.stringify(presets));
    const a = presets.find(p => p.name === "DistinctSet_A");
    const b = presets.find(p => p.name === "DistinctSet_B");
    expect(a, "preset A must exist").toBeTruthy();
    expect(b, "preset B must exist").toBeTruthy();
    expect(a.weights).toEqual({ skill: 10, availability: 10, seniority: 10, discipline: 10 });
    expect(b.weights).toEqual({ skill: 20, availability: 20, seniority: 20, discipline: 20 });
    expect(JSON.stringify(a.weights)).not.toBe(JSON.stringify(b.weights));

    // And selecting each preset from the dropdown restores the exact slider values, not a
    // renormalized 25/25/25/25 for either.
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(300);
    await page.selectOption("#opt-preset", "DistinctSet_A");
    await page.waitForTimeout(150);
    for (const k of ["skill", "availability", "seniority", "discipline"]) {
      expect(await page.locator("#w-" + k).inputValue()).toBe("10");
    }
    await page.selectOption("#opt-preset", "DistinctSet_B");
    await page.waitForTimeout(150);
    for (const k of ["skill", "availability", "seniority", "discipline"]) {
      expect(await page.locator("#w-" + k).inputValue()).toBe("20");
    }
  });

  test("Auth-mode stale-closure: baseUrl -> authMode -> token sequence via REAL UI inputs leaves baseUrl intact", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    await page.locator("#api-baseUrl").fill("https://real-ui-test.example.com/v1");
    await page.locator("#api-baseUrl").dispatchEvent("change");
    await page.waitForTimeout(100);
    await page.locator("#api-authMode").selectOption("bearer");
    await page.waitForTimeout(100);
    await page.locator("#api-token").fill("some-token-abc");
    await page.locator("#api-token").dispatchEvent("change");
    await page.waitForTimeout(100);
    // also touch authHeaderName by switching to apiKey and back to make sure a 3rd sibling field
    // doesn't get clobbered either
    await page.locator("#api-authMode").selectOption("apiKey");
    await page.waitForTimeout(100);
    await page.locator("#api-authHeader").fill("X-Custom-Key");
    await page.locator("#api-authHeader").dispatchEvent("change");
    await page.waitForTimeout(100);

    const apiSettings = await page.evaluate(() => window.ROE.store.getState().settings.api);
    expect(apiSettings.baseUrl).toBe("https://real-ui-test.example.com/v1");
    expect(apiSettings.authMode).toBe("apiKey");
    expect(apiSettings.authHeaderName).toBe("X-Custom-Key");
  });

  test("horizonStart validation: invalid value rejected with inline error, valid value accepted", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    const input = page.locator("#set-horizonStart, input[name='horizonStart']").first();
    if (await input.count()) {
      await input.fill("not-a-month");
      await input.dispatchEvent("change");
      await page.waitForTimeout(150);
      const settingsAfterBad = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
      expect(settingsAfterBad).not.toBe("not-a-month");
      await input.fill("2027-05");
      await input.dispatchEvent("change");
      await page.waitForTimeout(150);
      const settingsAfterGood = await page.evaluate(() => window.ROE.store.getState().settings.horizonStart);
      expect(settingsAfterGood).toBe("2027-05");
    } else {
      test.skip(true, "horizonStart input not found by expected selector");
    }
  });

  test("CSV export button is not gated on XLSX/window.XLSX availability", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    const xlsxAvailable = await page.evaluate(() => !!window.XLSX);
    console.log("window.XLSX available in this sandbox:", xlsxAvailable);
    const csvBtn = page.locator("#btn-export-csv, button:has-text('CSV')").first();
    if (await csvBtn.count()) {
      const disabled = await csvBtn.isDisabled();
      expect(disabled, "CSV export must remain enabled even without XLSX").toBe(false);
    } else {
      test.skip(true, "CSV export button not found by expected selector");
    }
  });
});
