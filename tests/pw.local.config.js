// LOCAL, UNCOMMITTED override — points Playwright at a pre-installed Chromium binary
// because this sandbox's proxy blocks cdn.playwright.dev (browser download) and
// cdn.jsdelivr.net (app CDNs). Not part of the runtime artifact or the committed harness.
const path = require("path");

module.exports = {
  testDir: "./specs",
  timeout: 30000,
  fullyParallel: false,
  reporter: [["list"]],
  use: {
    trace: "retain-on-failure",
    baseURL: "file://" + path.resolve(__dirname, ".."),
    launchOptions: {
      executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
    },
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
  ],
};
