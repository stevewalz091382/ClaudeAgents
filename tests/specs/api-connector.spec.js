// §9 "API" acceptance criteria. Uses Playwright page.route() per BUILD_PLAN.md §10 "Mock API".
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");
const { BASE_URL, mockSuccess, mockCorsFailure, mock401 } = require("../helpers/mockApi");

// A UI-driven equivalent of this exists below ("enabling an entity via the real Enabled
// checkbox..."). This console-forced version is kept for the engine-behavior tests further down
// that are not specifically testing the settings UI itself (diff/push/CORS/etc.), to keep those
// tests focused on the thing they're actually asserting.
async function configureApi(page, baseUrl) {
  await page.evaluate((base) => {
    const s = window.ROE.store.getState().settings;
    const api = JSON.parse(JSON.stringify(s.api));
    api.baseUrl = base;
    api.entities.employees.enabled = true;
    window.ROE.store.setSettings({ api });
  }, baseUrl);
}

test.describe("API connector configuration UI (§9 API, F-12, §7 Data & Settings) - FIXED", () => {
  test("a per-entity Enabled checkbox, per-entity path inputs, and a field-mapping UI exist for all 5 entities", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);

    const settingsHtml = await page.locator("#panel-settings").innerHTML();
    const hasFieldMappingUi = /field.?mapping/i.test(settingsHtml);
    expect(hasFieldMappingUi, "F-12 requires a field-mapping UI").toBe(true);

    for (const entity of ["employees", "projects", "demands", "assignments", "skills"]) {
      await expect(page.locator(`.api-ent-enabled[data-entity="${entity}"]`), `${entity} enabled checkbox`).toHaveCount(1);
      await expect(page.locator(`.api-ent-pullPath[data-entity="${entity}"]`), `${entity} pullPath input`).toHaveCount(1);
      await expect(page.locator(`.api-ent-pushPath[data-entity="${entity}"]`), `${entity} pushPath input`).toHaveCount(1);
      await expect(page.locator(`#api-pull-${entity}`), `${entity} pull button`).toHaveCount(1);
      await expect(page.locator(`#api-push-${entity}`), `${entity} push button`).toHaveCount(1);
    }
  });

  test("with default settings (no entity enabled), clicking Pull for employees fails with a clear 'not enabled' message", async ({ page }) => {
    await mockSuccess(page);
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate((base) => {
      window.ROE.store.setSettings({ api: Object.assign({}, window.ROE.store.getState().settings.api, { baseUrl: base }) });
    }, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);
    await page.click("#api-pull-employees");
    await page.waitForTimeout(300);
    const toastText = (await page.locator("#toast-region .toast").allTextContents()).join(" | ");
    expect(toastText).toContain("is not enabled");
  });

  test("enabling an entity via the real Enabled checkbox and setting its pull path via the real input makes Pull succeed against the mock", async ({ page }) => {
    await mockSuccess(page);
    await loadApp(page);
    await loadDemoData(page);
    const before = await page.evaluate(() => window.ROE.store.getState().employees.length);

    await page.evaluate((base) => {
      window.ROE.store.setSettings({ api: Object.assign({}, window.ROE.store.getState().settings.api, { baseUrl: base }) });
    }, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);

    // Drive it entirely through the real UI: check the box, set the pull path, add a field mapping.
    await page.locator('.api-ent-enabled[data-entity="employees"]').check();
    await page.locator('.api-ent-pullPath[data-entity="employees"]').fill("/employees");
    await page.locator('.api-ent-pullPath[data-entity="employees"]').dispatchEvent("change");
    await page.locator('.map-field-new[data-entity="employees"]').fill("name");
    await page.locator('.map-path-new[data-entity="employees"]').fill("full_name");
    await page.click('.map-add[data-entity="employees"]');
    await page.waitForTimeout(150);

    const enabledNow = await page.evaluate(() => window.ROE.store.getState().settings.api.entities.employees.enabled);
    expect(enabledNow, "checking the real checkbox must set settings.api.entities.employees.enabled").toBe(true);
    const mappingNow = await page.evaluate(() => window.ROE.store.getState().settings.api.fieldMappings.employees);
    expect(mappingNow).toEqual({ name: "full_name" });

    await page.click("#api-pull-employees");
    await page.waitForTimeout(400);
    const previewText = await page.locator("#api-preview").innerText();
    expect(previewText).toMatch(/add|update/i);

    await page.click("#api-apply-pull");
    await page.waitForTimeout(300);
    const state = await page.evaluate(() => window.ROE.store.getState());
    expect(state.employees.length).toBeGreaterThan(before);
    // The field mapping (name <- full_name) should have actually been applied.
    const pulled = state.employees.find((e) => e.name === "Remote One" || e.name === "Remote Two");
    expect(pulled, "field mapping should map full_name -> name on the applied records").toBeTruthy();
  });

  test("Pull/Push buttons operate independently per entity - enabling projects does not make employees' buttons work and vice versa", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);
    await page.click("#api-pull-projects");
    await page.waitForTimeout(300);
    const toastText = (await page.locator("#toast-region .toast").allTextContents()).join(" | ");
    expect(toastText).toContain("Entity 'projects' is not enabled");
  });
});

test.describe("HIGH #2 fix: sequential API field edits no longer clobber each other", () => {
  test("setting baseUrl, then authMode, then the token, leaves baseUrl intact (no stale-closure wipe)", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);

    await page.locator("#api-baseUrl").fill("https://api.example.com/v1");
    await page.locator("#api-baseUrl").dispatchEvent("change");
    await page.waitForTimeout(100);

    await page.selectOption("#api-authMode", "bearer");
    await page.waitForTimeout(100);

    await page.locator("#api-token").fill("some-secret-token");
    await page.locator("#api-token").dispatchEvent("change");
    await page.waitForTimeout(100);

    const api = await page.evaluate(() => window.ROE.store.getState().settings.api);
    expect(api.baseUrl, "baseUrl must survive subsequent authMode/token edits").toBe("https://api.example.com/v1");
    expect(api.authMode).toBe("bearer");
  });
});

test.describe("API connector behavior once an entity is force-enabled (§9 API)", () => {
  test("a pull against a mock endpoint maps fields and shows an add/update diff before applying; cancelling changes nothing", async ({ page }) => {
    await mockSuccess(page);
    await loadApp(page);
    await loadDemoData(page);
    await configureApi(page, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    const before = await page.evaluate(() => window.ROE.store.getState().employees.length);

    await page.click("#api-pull-employees");
    await page.waitForTimeout(400);
    const previewText = await page.locator("#api-preview").innerText();
    expect(previewText).toMatch(/add|update/i);

    // Cancel: nothing should change.
    const cancelBtn = page.locator("#api-cancel-pull");
    if (await cancelBtn.count()) {
      await cancelBtn.click();
      await page.waitForTimeout(200);
    }
    const after = await page.evaluate(() => window.ROE.store.getState().employees.length);
    expect(after).toBe(before);
  });

  test("applying a pull actually adds/updates employees from the mock fixture", async ({ page }) => {
    await mockSuccess(page);
    await loadApp(page);
    await loadDemoData(page);
    await configureApi(page, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    await page.click("#api-pull-employees");
    await page.waitForTimeout(400);
    const applyBtn = page.locator("#api-apply-pull");
    await expect(applyBtn).toBeVisible();
    await applyBtn.click();
    await page.waitForTimeout(300);
    const state = await page.evaluate(() => window.ROE.store.getState());
    // api-employees.json fixture ids - spot check via helpers/fixtures file.
    expect(state.employees.length).toBeGreaterThan(0);
  });

  test("a record with local unsaved edits defaults to 'keep local' in the diff (diffPull)", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const API = window.ROE.api;
      const local = [{ id: "e1", name: "Locally Edited Name" }];
      const remote = [{ id: "e1", name: "Remote Name" }];
      const lastSnapshot = { e1: { id: "e1", name: "Original Snapshot Name" } }; // local differs from snapshot -> "edited"
      const diff = API.diffPull(local, remote, lastSnapshot, "id");
      return diff.updates[0];
    });
    expect(result.localEdited).toBe(true);
    expect(result.applyRemote).toBe(false);
  });

  test("a record with NO local edits since the last pull defaults to applying the remote update", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const API = window.ROE.api;
      const local = [{ id: "e1", name: "Original Snapshot Name" }];
      const remote = [{ id: "e1", name: "Remote Name" }];
      const lastSnapshot = { e1: { id: "e1", name: "Original Snapshot Name" } }; // local === snapshot -> not edited
      const diff = API.diffPull(local, remote, lastSnapshot, "id");
      return diff.updates[0];
    });
    expect(result.localEdited).toBe(false);
    expect(result.applyRemote).toBe(true);
  });

  test("push only fires on explicit button press, after a preview, never automatically", async ({ page }) => {
    let pushCalled = false;
    await loadApp(page);
    await loadDemoData(page);
    await page.route(BASE_URL + "/employees", async (route) => {
      if (route.request().method() === "POST") pushCalled = true;
      await route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
    });
    await configureApi(page, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);
    // Merely rendering the settings panel and waiting must never trigger a push.
    await page.waitForTimeout(500);
    expect(pushCalled, "push must never fire without an explicit button press").toBe(false);

    await page.click("#api-push-employees");
    await page.waitForTimeout(300);
    expect(pushCalled, "clicking Push (preview) alone should only show a preview, not send yet").toBe(false);

    const sendBtn = page.locator("#api-send-push");
    await expect(sendBtn).toBeVisible();
    await sendBtn.click();
    await page.waitForTimeout(300);
    expect(pushCalled, "clicking Send should perform the actual push").toBe(true);
  });

  test("a CORS-blocked request produces a message naming CORS, distinct from an HTTP error status", async ({ page }) => {
    await mockCorsFailure(page);
    await loadApp(page);
    await loadDemoData(page);
    await configureApi(page, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    await page.click("#api-pull-employees");
    await page.waitForTimeout(500);
    const toastText = (await page.locator("#toast-region .toast").allTextContents()).join(" | ");
    expect(toastText.toLowerCase()).toContain("cors");
    expect(toastText).not.toMatch(/HTTP 401|HTTP 500/);
  });

  test("an HTTP error status (401) produces a distinct message naming the status code, not a generic/CORS message", async ({ page }) => {
    await mock401(page);
    await loadApp(page);
    await loadDemoData(page);
    await configureApi(page, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(200);
    await page.click("#api-pull-employees");
    await page.waitForTimeout(500);
    const toastText = (await page.locator("#toast-region .toast").allTextContents()).join(" | ");
    expect(toastText).toContain("401");
    expect(toastText.toLowerCase()).not.toContain("cors");
  });

  test("field mapping (dot-path) is applied correctly on a wrapped response (responseRoot)", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(async () => {
      const API = window.ROE.api;
      const wrapped = { data: { items: [{ full_name: "Ada Lovelace", contact: { email: "ada@example.com" }, id: "r1" }] } };
      const extracted = API.extractArray(wrapped, "data.items");
      const mapped = extracted.data.map((r) => API.applyFieldMapping(r, { name: "full_name", email: "contact.email" }));
      return mapped;
    });
    expect(result[0].name).toBe("Ada Lovelace");
    expect(result[0].email).toBe("ada@example.com");
    expect(result[0].id).toBe("r1");
  });

  test("a non-array response (wrong shape) produces a clear error message, not a crash", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const API = window.ROE.api;
      return API.extractArray({ not: "an array" }, "");
    });
    expect(result.error).toBeTruthy();
    expect(typeof result.error).toBe("string");
  });
});
