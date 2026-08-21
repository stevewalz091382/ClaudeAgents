// Dev-only test helper. Registers page.route() mocks for ROE.api so the connector (Task 18) can
// be exercised without a real backend, per BUILD_PLAN.md §10 ("Mock API").
const fs = require("fs");
const path = require("path");

const EMPLOYEES_FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fixtures", "api-employees.json"), "utf8"));
const EMPLOYEES_WRAPPED_FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fixtures", "api-employees-wrapped.json"), "utf8"));

const BASE_URL = "https://mock-roe-api.test";

// Happy path: GET /employees -> 200 JSON array.
async function mockSuccess(page, { wrapped = false } = {}) {
  await page.route(BASE_URL + "/employees", async (route) => {
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(wrapped ? EMPLOYEES_WRAPPED_FIXTURE : EMPLOYEES_FIXTURE) });
  });
}

// Auth failure: GET /employees -> 401.
async function mock401(page) {
  await page.route(BASE_URL + "/employees", async (route) => {
    await route.fulfill({ status: 401, contentType: "application/json", body: JSON.stringify({ error: "Unauthorized" }) });
  });
}

// Simulated CORS failure: abort the request the way a browser does when a preflight/response is
// blocked for lacking Access-Control-Allow-Origin. Playwright's route.abort() surfaces as a fetch
// TypeError with no HTTP status, matching ROE.api's CORS-detection branch.
async function mockCorsFailure(page) {
  await page.route(BASE_URL + "/employees", async (route) => {
    await route.abort("failed");
  });
}

module.exports = { BASE_URL, mockSuccess, mock401, mockCorsFailure, EMPLOYEES_FIXTURE, EMPLOYEES_WRAPPED_FIXTURE };
