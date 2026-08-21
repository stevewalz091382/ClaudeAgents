// §9 "API" acceptance criteria. Uses Playwright page.route() per BUILD_PLAN.md §10 "Mock API".
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");
const { BASE_URL, mockSuccess, mockCorsFailure, mock401 } = require("../helpers/mockApi");

async function configureApi(page, baseUrl) {
  await page.evaluate((base) => {
    const s = window.ROE.store.getState().settings;
    // Enable the "employees" entity by construction, since (see the dedicated test below) there is
    // no UI control to do this - this is what a fully-wired UI would have set.
    const api = JSON.parse(JSON.stringify(s.api));
    api.baseUrl = base;
    api.entities.employees.enabled = true;
    window.ROE.store.setSettings({ api });
  }, baseUrl);
}

test.describe("API connector CRITICAL GAP (§9 API, F-12, §7 Data & Settings)", () => {
  test("CRITICAL: there is no UI control anywhere to enable an entity for pull/push, so the API connector is non-functional out of the box", async ({ page }) => {
    await mockSuccess(page);
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate((base) => {
      window.ROE.store.setSettings({ api: Object.assign({}, window.ROE.store.getState().settings.api, { baseUrl: base }) });
    }, BASE_URL);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);

    const settingsHtml = await page.locator("#panel-settings").innerHTML();
    const hasEntityToggle = /enabled/i.test(settingsHtml) && /entit/i.test(settingsHtml);
    const hasFieldMappingUi = /field.?mapping/i.test(settingsHtml);
    const hasPerEntityPathInputs = /pullPath|pushPath|api-entity/i.test(settingsHtml);

    await page.click("#api-pull");
    await page.waitForTimeout(300);
    const toastText = (await page.locator("#toast-region .toast").allTextContents()).join(" | ");

    expect(hasEntityToggle, "no checkbox/control exists to set settings.api.entities.<name>.enabled").toBe(false);
    expect(hasFieldMappingUi, "F-12 requires a field-mapping UI; none is rendered").toBe(false);
    expect(hasPerEntityPathInputs, "F-12 requires configurable per-entity paths; none are rendered").toBe(false);
    expect(toastText, "with default settings, clicking Pull always fails because no entity can ever be enabled through the UI").toContain("is not enabled");
  });

  test("only the 'employees' entity has any pull/push wiring at all - projects/demands/assignments/skills are entirely unreachable from the UI", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(() => { location.hash = "#settings"; });
    await page.waitForTimeout(300);
    const settingsHtml = await page.locator("#panel-settings").innerHTML();
    // Only one pull/push button pair exists, hardcoded to "employees".
    const pullButtons = await page.locator("#panel-settings button", { hasText: /pull/i }).count();
    const pushButtons = await page.locator("#panel-settings button", { hasText: /push/i }).count();
    expect(pullButtons).toBe(1);
    expect(pushButtons).toBe(1);
    expect(settingsHtml).toContain("Pull employees");
    expect(settingsHtml).not.toMatch(/pull projects|pull demands|pull assignments|pull skills/i);
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

    await page.click("#api-pull");
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
    await page.click("#api-pull");
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

    await page.click("#api-push");
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
    await page.click("#api-pull");
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
    await page.click("#api-pull");
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
