// §9 "Optimizer" (auto-staff) and §9 "Alerts" acceptance criteria against the real demo dataset,
// loaded through the actual UI action per BUILD_PLAN.md §10.
const { test, expect } = require("@playwright/test");
const { loadApp, loadDemoData } = require("../helpers/loadApp");

test.describe("Auto-staff solver (§4.5, §9 Optimizer) against demo data", () => {
  test("auto-staff never produces an assignment that pushes any employee-month above effectiveCapacity", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, SCORE = window.ROE.score, CALC = window.ROE.calc;
      const state = STORE.getState();
      const violations = [];
      state.projects.forEach((project) => {
        const auto = SCORE.autoStaff(state, project.id, state.settings.weights);
        // Simulate applying all proposals together (as "Commit all" would) and check capacity.
        const simState = JSON.parse(JSON.stringify(state));
        simState.assignments = simState.assignments.concat(auto.proposals);
        const idx = CALC.buildIndexes(simState);
        auto.proposals.forEach((p) => {
          const emp = simState.employees.find((e) => e.id === p.employeeId);
          for (const m in p.allocationByMonth) {
            const committed = CALC.committed(emp.id, m, idx);
            const cap = CALC.effectiveCapacity(emp, m, idx, simState.settings);
            if (committed > cap + 1e-6) {
              violations.push({ projectId: project.id, employeeId: emp.id, month: m, committed, cap });
            }
          }
        });
      });
      return violations;
    });
    expect(result).toEqual([]);
  });

  test("auto-staff on a project with zero eligible employees yields zero assignments and an explicit unfilled reason per opening", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, SCORE = window.ROE.score, M = window.ROE.model, U = window.ROE.util;
      const state = STORE.getState();
      // Deactivate everyone so nobody is eligible, then run auto-staff on a real project.
      const clone = JSON.parse(JSON.stringify(state));
      clone.employees.forEach((e) => { e.active = false; });
      const project = clone.projects[0];
      const auto = SCORE.autoStaff(clone, project.id, clone.settings.weights);
      return { proposalCount: auto.proposals.length, unfilled: auto.unfilled };
    });
    expect(result.proposalCount).toBe(0);
    expect(result.unfilled.length).toBeGreaterThan(0);
    expect(result.unfilled.every((u) => typeof u.reason === "string" && u.reason.length > 0)).toBe(true);
  });

  test("nothing is written to the store until Commit is pressed (auto-staff preview is inert)", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const before = await page.evaluate(() => window.ROE.store.getState().assignments.length);
    await page.evaluate(() => {
      const STORE = window.ROE.store, SCORE = window.ROE.score;
      const state = STORE.getState();
      const project = state.projects[0];
      // Calling the pure solver directly must not mutate the store.
      SCORE.autoStaff(state, project.id, state.settings.weights);
    });
    const after = await page.evaluate(() => window.ROE.store.getState().assignments.length);
    expect(after).toBe(before);
  });
});

test.describe("Demo data alert coverage (§9 Alerts)", () => {
  test("demo data fires at least one alert from each of the 8 rules", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const bySeverityRule = await page.evaluate(() => {
      const STORE = window.ROE.store, ALERTS = window.ROE.alerts;
      const state = STORE.getState();
      const alerts = ALERTS.scan(state, state.settings.alertThresholds);
      const rules = {};
      alerts.forEach((a) => { rules[a.ruleId] = (rules[a.ruleId] || 0) + 1; });
      return rules;
    });
    const expectedRules = [
      "SUSTAINED_OVERALLOC", "OVER_TARGET", "CTX_OVERLOAD", "BURNOUT_COMPOSITE",
      "BENCH_RISK", "UNSTAFFED_DEMAND", "TEAM_SIZE", "SKILL_GAP",
    ];
    const missing = expectedRules.filter((r) => !bySeverityRule[r]);
    expect(missing, "rules that never fired on demo data: " + JSON.stringify(missing) + " full counts: " + JSON.stringify(bySeverityRule)).toEqual([]);
  });

  test("alerts are derived, never persisted: clearing store and rebuilding identical state reproduces an identical alert set", async ({ page }) => {
    await loadApp(page);
    await loadDemoData(page);
    const result = await page.evaluate(() => {
      const STORE = window.ROE.store, ALERTS = window.ROE.alerts, U = window.ROE.util;
      const state1 = STORE.getState();
      const alerts1 = ALERTS.scan(state1, state1.settings.alertThresholds);
      // Rebuild an equivalent canonical state from scratch (simulating export/reimport) and rescan.
      const rebuilt = JSON.parse(JSON.stringify(state1));
      const alerts2 = ALERTS.scan(rebuilt, rebuilt.settings.alertThresholds);
      const norm = (arr) => arr.map((a) => ({ severity: a.severity, ruleId: a.ruleId, subjectType: a.subjectType, subjectId: a.subjectId, monthKeys: a.monthKeys }))
        .sort((a, b) => (a.ruleId + a.subjectId).localeCompare(b.ruleId + b.subjectId));
      return U.deepEqual(norm(alerts1), norm(alerts2));
    });
    expect(result).toBe(true);
  });
});
