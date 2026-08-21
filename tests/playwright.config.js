// Dev-only Playwright config for testing ../index.html. Does not affect the runtime artifact.
// Loads the app straight from the filesystem (file://) as required by BUILD_PLAN.md §9 ("Global").
const path = require("path");

module.exports = {
  testDir: "./specs",
  timeout: 30000,
  fullyParallel: false,
  reporter: [["list"]],
  use: {
    trace: "retain-on-failure",
    baseURL: "file://" + path.resolve(__dirname, ".."),
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
  ],
};
