// §9 "Performance & a11y" acceptance criteria: 1,000 employees / 200 projects / 5,000 assignments.
// No dev helper for generating this synthetic dataset exists anywhere in the repo (grepped for
// "synthetic"/"perfSeed"/etc. in index.html and tests/helpers - none found), despite BUILD_PLAN.md
// Task 19 calling for one. This spec builds the dataset itself, directly against the real
// ROE.store/ROE.ui, to check both the pure-calc claim AND the real panel-switch-under-load claim
// the Coder's self-report says was never verified.
const { test, expect } = require("@playwright/test");
const { loadApp } = require("../helpers/loadApp");

function buildLargeDatasetScript() {
  return () => {
    const C = window.ROE.const, M = window.ROE.model, U = window.ROE.util;
    const months = U.monthKeys("2026-01", 12);
    const employees = [], employeeSkills = [], projects = [], demands = [], assignments = [];
    for (let i = 0; i < 1000; i++) {
      employees.push(M.newEmployee({
        id: "pe_" + i, name: "Perf Employee " + i, email: "pe" + i + "@example.com",
        level: C.EMP_LEVELS[i % 4], discipline: C.DISCIPLINES[i % C.DISCIPLINES.length],
        office: "Office " + (i % 6), businessGroup: C.BUSINESS_GROUPS[i % 5],
        targetUtil: 80 + (i % 3) * 5, mentorRole: "None", active: true,
      }));
    }
    for (let i = 0; i < 200; i++) {
      projects.push(M.newProject({
        id: "pp_" + i, name: "Perf Project " + i, client: "Client " + i,
        market: C.BUSINESS_GROUPS[i % 5], discipline: C.DISCIPLINES[i % C.DISCIPLINES.length],
        phase: C.PROJECT_PHASES[i % C.PROJECT_PHASES.length], budget: 1000000, bimLevel: "BIM Level 1",
        teamMin: 2, teamMax: 20, priority: (i % 5) + 1, status: "Active",
      }));
      demands.push(M.newDemand({
        id: "pd_" + i, projectId: "pp_" + i, title: "Perf Demand " + i,
        discipline: C.DISCIPLINES[i % C.DISCIPLINES.length], minLevel: "Junior",
        requiredSkills: [], openings: 2,
        allocationByMonth: months.reduce((o, m) => (o[m] = 50, o), {}),
      }));
    }
    let seq = 0;
    for (let i = 0; i < 5000; i++) {
      const empIdx = i % 1000, prjIdx = i % 200;
      const alloc = {};
      months.forEach((m, mi) => { if (mi % 2 === 0) alloc[m] = 20 + (i % 4) * 10; });
      assignments.push(M.newAssignment({
        id: "pa_" + (seq++), projectId: "pp_" + prjIdx, employeeId: "pe_" + empIdx,
        demandId: "pd_" + prjIdx, allocationByMonth: alloc, status: "Committed", source: "import",
      }));
    }
    const state = window.ROE.store.getState();
    state.employees = employees; state.projects = projects; state.demands = demands;
    state.assignments = assignments; state.employeeSkills = employeeSkills; state.mentorships = [];
    state.skills = C.SEED_SKILLS.map((s) => M.newSkill({ id: "skl_" + s.code.toLowerCase(), code: s.code, name: s.name, category: s.category }));
    window.ROE.store.markDirty();
    return { employees: employees.length, projects: projects.length, assignments: assignments.length };
  };
}

test.describe("Performance at design scale (§9 Performance & a11y, N-1)", () => {
  test.setTimeout(60000);

  test("pure ROE.calc.buildIndexes over 5,000 assignments x 12 months completes in < 500ms", async ({ page }) => {
    await loadApp(page);
    const counts = await page.evaluate(buildLargeDatasetScript());
    expect(counts.assignments).toBe(5000);
    const ms = await page.evaluate(() => {
      const state = window.ROE.store.getState();
      const t0 = performance.now();
      window.ROE.calc.buildIndexes(state);
      return performance.now() - t0;
    });
    console.log("buildIndexes ms:", ms);
    expect(ms).toBeLessThan(500);
  });

  test("full alert scan at design scale completes in < 2s", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(buildLargeDatasetScript());
    const ms = await page.evaluate(() => {
      const state = window.ROE.store.getState();
      const t0 = performance.now();
      window.ROE.alerts.scan(state, state.settings.alertThresholds);
      return performance.now() - t0;
    });
    console.log("alert scan ms:", ms);
    expect(ms).toBeLessThan(2000);
  });

  test("REAL UI: switching to every panel at design scale renders in < 400ms each", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(buildLargeDatasetScript());
    await page.evaluate(() => { window.ROE.ui.renderAll(); });
    await page.waitForTimeout(200);

    const panels = ["overview", "skills", "projects", "optimizer", "mentorship", "timeline", "alerts", "settings"];
    const timings = {};
    for (const panel of panels) {
      const ms = await page.evaluate((p) => {
        const t0 = performance.now();
        window.ROE.ui.navigate(p);
        return performance.now() - t0;
      }, panel);
      timings[panel] = ms;
      await page.waitForTimeout(50);
    }
    console.log("panel switch timings (ms):", JSON.stringify(timings, null, 2));
    const slow = Object.entries(timings).filter(([, ms]) => ms >= 400);
    expect(slow, "panels exceeding the 400ms budget at design scale: " + JSON.stringify(slow)).toEqual([]);
  });

  test("REAL UI: repeated panel switching at design scale does not progressively degrade (no unbounded re-render cost)", async ({ page }) => {
    await loadApp(page);
    await page.evaluate(buildLargeDatasetScript());
    await page.evaluate(() => { window.ROE.ui.renderAll(); });
    const samples = [];
    for (let i = 0; i < 10; i++) {
      const ms = await page.evaluate((idx) => {
        const t0 = performance.now();
        window.ROE.ui.navigate(idx % 2 === 0 ? "skills" : "overview");
        return performance.now() - t0;
      }, i);
      samples.push(ms);
    }
    console.log("repeated switch samples (ms):", JSON.stringify(samples));
    const first3Avg = samples.slice(0, 3).reduce((a, b) => a + b, 0) / 3;
    const last3Avg = samples.slice(-3).reduce((a, b) => a + b, 0) / 3;
    expect(last3Avg, "later panel switches should not be dramatically slower than early ones").toBeLessThan(Math.max(400, first3Avg * 3));
  });
});
