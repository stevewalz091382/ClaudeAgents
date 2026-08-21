// §9 "Performance & a11y" - "every input has an associated <label> or aria-label" and every panel
// reachable by keyboard. Not a formal WCAG audit (per plan N-3/§9), just the two literal checks.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

const PANELS = ["overview", "skills", "projects", "optimizer", "mentorship", "timeline", "alerts", "settings"];

test.describe("Accessibility literal checks (§9 Performance & a11y)", () => {
  for (const panel of PANELS) {
    test(`every input/select/textarea on the "${panel}" panel has a label or aria-label`, async ({ page }) => {
      await loadApp(page);
      await loadDemoData(page);
      await page.evaluate((p) => { location.hash = "#" + p; }, panel);
      await page.waitForTimeout(300);
      const unlabeled = await page.evaluate(() => {
        const root = document.querySelector(".panel.active");
        if (!root) return [];
        const controls = Array.from(root.querySelectorAll("input, select, textarea"));
        return controls.filter((el) => {
          if (el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby")) return false;
          if (el.closest("label")) return false;
          if (el.id) {
            const forLabel = document.querySelector(`label[for="${el.id}"]`);
            if (forLabel) return false;
          }
          return true;
        }).map((el) => el.outerHTML.slice(0, 120));
      });
      expect(unlabeled, `unlabeled controls on ${panel}: ${JSON.stringify(unlabeled)}`).toEqual([]);
    });
  }

  test("every nav panel link is reachable via Tab and activates on Enter (keyboard-only navigation)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    for (const panel of PANELS) {
      const link = page.locator(`#nav a[data-panel="${panel}"]`);
      await link.focus();
      await expect(link).toBeFocused();
      await page.keyboard.press("Enter");
      await page.waitForTimeout(150);
      const activePanel = await page.evaluate(() => document.querySelector(".panel.active").id);
      expect(activePanel).toBe("panel-" + panel);
    }
  });

  test("modal is dismissible with Escape (keyboard-only)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    await page.evaluate(() => { location.hash = "#optimizer"; });
    await page.waitForTimeout(300);
    const firstCard = page.locator(".candidate-card").first();
    await expect(firstCard).toBeVisible();
    await firstCard.locator(".review-candidate").click();
    await page.waitForTimeout(150);
    await expect(page.locator("#modal-root .modal")).toBeVisible();
    await page.keyboard.press("Escape");
    await page.waitForTimeout(150);
    const modalCount = await page.locator("#modal-root .modal").count();
    expect(modalCount).toBe(0);
  });
});
