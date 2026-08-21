// Dev-only test helper. Loads index.html from file:// (per BUILD_PLAN.md §9 "Global") and waits
// for the ROE global namespace to be attached before handing control back to the test.
const path = require("path");

async function loadApp(page, { hash } = {}) {
  const url = "file://" + path.resolve(__dirname, "..", "..", "index.html") + (hash ? "#" + hash : "");
  await page.goto(url, { waitUntil: "load" });
  await page.waitForFunction(() => !!(window.ROE && window.ROE.store && window.ROE.calc));
  return page;
}

// Loads the demo/seed dataset via the real UI action (exercises the "Load demo data" button,
// not just the underlying pure function), then waits for the debounced store save/render cycle.
async function loadDemoData(page) {
  await page.click("#btn-load-demo");
  await page.waitForFunction(() => window.ROE.store.getState().employees.length > 0);
}

module.exports = { loadApp, loadDemoData };
