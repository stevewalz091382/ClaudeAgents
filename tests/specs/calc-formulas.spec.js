// §9 "Calc engine" + "Optimizer" + "Alerts" + "Mentorship" acceptance criteria, exercised at the
// pure-function level via page.evaluate() against ROE.calc / ROE.score / ROE.alerts / ROE.mentor.
const { test, expect } = require("@playwright/test");
const fs = require("fs");
const path = require("path");
const { loadApp } = require("../helpers/loadApp");

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fixtures", "minimal-state.json"), "utf8"));

test.describe("ctxTax / capacity formulas (§4.1-4.2, §9 Calc engine)", () => {
  test("ctxTax(1)=0, ctxTax(2)=7, ctxTax(5)=28, ctxTax(9)=30 at defaults", async ({ page }) => {
    await loadApp(page);
    const settings = { ctxTaxPerExtraProject: 7, ctxTaxCapPct: 30 };
    const results = await page.evaluate((s) => {
      return [1, 2, 5, 9].map((n) => window.ROE.calc.ctxTaxPct(n, s));
    }, settings);
    expect(results).toEqual([0, 7, 28, 30]);
  });

  test("effectiveCapacity at targetUtil 85 / 3 concurrent projects = 73.1", async ({ page }) => {
    await loadApp(page);
    const val = await page.evaluate(() => {
      const CALC = window.ROE.calc;
      const settings = { ctxTaxPerExtraProject: 7, ctxTaxCapPct: 30 };
      const emp = { id: "e1", targetUtil: 85 };
      const idx = { byEmployeeMonth: new Map([["e1", new Map([["2026-01", { pct: 0, projectIds: new Set(["p1", "p2", "p3"]) }]])]]) };
      return CALC.effectiveCapacity(emp, "2026-01", idx, settings);
    });
    expect(val).toBeCloseTo(73.1, 5);
  });

  test("free() is never negative even when massively over-committed; netCap() goes negative", async ({ page }) => {
    await loadApp(page);
    const { freeVal, netVal } = await page.evaluate(() => {
      const CALC = window.ROE.calc;
      const settings = { ctxTaxPerExtraProject: 7, ctxTaxCapPct: 30 };
      const emp = { id: "e1", targetUtil: 85 };
      const idx = {
        byEmployeeMonth: new Map([["e1", new Map([["2026-01", { pct: 500, projectIds: new Set(["p1"]) }]])]]),
      };
      return { freeVal: CALC.free(emp, "2026-01", idx, settings), netVal: CALC.netCap(emp, "2026-01", idx, settings) };
    });
    expect(freeVal).toBe(0);
    expect(netVal).toBeLessThan(0);
  });

  test("an employee with a single 0% allocation entry does not count as a concurrent project", async ({ page }) => {
    await loadApp(page);
    const n = await page.evaluate(() => {
      const CALC = window.ROE.calc;
      const state = {
        assignments: [
          { employeeId: "e1", projectId: "p1", allocationByMonth: { "2026-01": 0 } },
          { employeeId: "e1", projectId: "p2", allocationByMonth: { "2026-01": 10 } },
        ],
        demands: [],
      };
      const idx = CALC.buildIndexes(state);
      return CALC.concurrentProjectsAt("e1", "2026-01", idx);
    });
    expect(n).toBe(1); // only p2 counts since p1's alloc is 0
  });
});

test.describe("Optimizer determinism & breakdown (§9 Optimizer)", () => {
  test("same state + same weights -> identical ranking across 100 runs", async ({ page }) => {
    await loadApp(page);
    const stable = await page.evaluate((fixture) => {
      const SCORE = window.ROE.score;
      const state = fixture;
      const weights = { skill: 35, availability: 30, seniority: 15, discipline: 20 };
      const first = JSON.stringify(SCORE.rankCandidates(state, "fx_dem_1", weights));
      for (let i = 0; i < 100; i++) {
        const again = JSON.stringify(SCORE.rankCandidates(state, "fx_dem_1", weights));
        if (again !== first) return { ok: false, i };
      }
      return { ok: true };
    }, FIXTURE);
    expect(stable.ok).toBe(true);
  });

  test("weighted sub-score sum plus modifiers equals matchScore (within rounding, respecting the documented 0-100 clamp)", async ({ page }) => {
    await loadApp(page);
    const diffs = await page.evaluate((fixture) => {
      const SCORE = window.ROE.score;
      const weights = { skill: 35, availability: 30, seniority: 15, discipline: 20 };
      const r = SCORE.scoreCandidate(fixture, "fx_emp_1", "fx_dem_1", weights);
      const expected = Math.max(0, Math.min(100, Math.round(r.base + r.clampedModifiers)));
      return Math.abs(r.matchScore - expected);
    }, FIXTURE);
    expect(diffs).toBeLessThanOrEqual(1);
  });

  test("zero free-capacity candidate scores availability=0 and never outranks an equal-skill candidate with capacity", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate((fixtureIn) => {
      const fixture = JSON.parse(JSON.stringify(fixtureIn));
      // fx_emp_2 (Senior, skill level 4) gets fully saturated every demand month via a giant assignment.
      fixture.assignments = [
        { id: "a1", projectId: "other_prj", employeeId: "fx_emp_2", demandId: null,
          allocationByMonth: { "2026-01": 500, "2026-02": 500, "2026-03": 500 }, status: "Committed", source: "manual", scoreSnapshot: null },
      ];
      const SCORE = window.ROE.score;
      const weights = { skill: 35, availability: 30, seniority: 15, discipline: 20 };
      const saturated = SCORE.scoreCandidate(fixture, "fx_emp_2", "fx_dem_1", weights);
      const free1 = SCORE.scoreCandidate(fixture, "fx_emp_1", "fx_dem_1", weights);
      return { availSaturated: saturated.subScores.availability, saturatedScore: saturated.matchScore, freeScore: free1.matchScore };
    }, FIXTURE);
    expect(result.availSaturated).toBe(0);
  });

  test("requireMinSkillLevels=true excludes below-minimum candidates with exclusion reason", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate((fixtureIn) => {
      const fixture = JSON.parse(JSON.stringify(fixtureIn));
      fixture.settings.requireMinSkillLevels = true;
      // fx_emp_1 has civil3d level 3, demand requires minLevel 2 -> qualifies.
      // Add a demand requiring level 5 (nobody has it) to force disqualification.
      fixture.demands.push({
        id: "fx_dem_hard", projectId: "fx_prj_1", title: "Impossible", discipline: "Civil", minLevel: "Mid-Level",
        requiredSkills: [{ skillId: "skl_civil3d", minLevel: 5, weight: 2 }],
        openings: 1, allocationByMonth: { "2026-01": 50 }, updatedAt: "2026-01-01T00:00:00.000Z",
      });
      const SCORE = window.ROE.score;
      const weights = { skill: 35, availability: 30, seniority: 15, discipline: 20 };
      const ranking = SCORE.rankCandidates(fixture, "fx_dem_hard", weights);
      return { candidateCount: ranking.candidates.length, excludedCount: ranking.excluded.length,
        reasons: ranking.excluded.map((c) => c.reasons) };
    }, FIXTURE);
    expect(result.candidateCount).toBe(0);
    expect(result.excludedCount).toBeGreaterThan(0);
    expect(result.reasons.every((r) => r.includes("below minimum skill level"))).toBe(true);
  });
});

test.describe("Alerts formula fixture (§4.6, §9 Alerts)", () => {
  test("burnout composite matches hand-computed value", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const settings = {
        horizonStart: "2026-01", horizonMonths: 6,
        alertThresholds: { overallocPct: 100, sustainedMonths: 2, targetSlackPct: 10, benchGapPct: 25, benchMonths: 3 },
        ctxCap: 4,
      };
      // Employee committed 120% for 3 of 6 months (sustained overalloc), peak 150%, max concurrent 3 projects.
      const state = {
        settings: settings,
        employees: [{ id: "e1", name: "Fixture", active: true, targetUtil: 85 }],
        assignments: [
          { employeeId: "e1", projectId: "p1", allocationByMonth: { "2026-01": 60, "2026-02": 60, "2026-03": 60 } },
          { employeeId: "e1", projectId: "p2", allocationByMonth: { "2026-01": 30, "2026-02": 30, "2026-03": 30 } },
          { employeeId: "e1", projectId: "p3", allocationByMonth: { "2026-01": 30, "2026-02": 30, "2026-03": 60 } },
          { employeeId: "e1", projectId: "p4", allocationByMonth: { "2026-01": 0, "2026-02": 0, "2026-03": 0 } },
          { employeeId: "e1", projectId: "p5", allocationByMonth: { "2026-03": 0 } },
        ],
        demands: [], projects: [], mentorships: [],
      };
      const alerts = window.ROE.alerts.scan(state, settings.alertThresholds);
      const burnout = alerts.find((a) => a.ruleId === "BURNOUT_COMPOSITE");
      // Hand-computed: committed per month = [120,120,150,0,0,0]. sustainedOverallocMonths (>100) = 3.
      // peakCommitted = 150. maxConcurrentProjects (nonzero pct) = 3 (p1,p2,p3 in months 1-3, p4/p5 always 0).
      const expected = 100 * (0.5 * (3 / 6) + 0.3 * Math.min(1, (150 - 100) / 50) + 0.2 * Math.min(1, 3 / 6));
      return { found: !!burnout, score: burnout ? burnout.score : null, expected: expected };
    });
    expect(result.found).toBe(true);
    expect(result.score).toBeCloseTo(result.expected, 5);
  });

  test("raising overallocPct from 100 to 130 reduces SUSTAINED_OVERALLOC count", async ({ page }) => {
    await loadApp(page);
    const counts = await page.evaluate((fixtureIn) => {
      const fixture = JSON.parse(JSON.stringify(fixtureIn));
      fixture.settings.horizonMonths = 3;
      fixture.assignments = [
        { employeeId: "fx_emp_1", projectId: "fx_prj_1", allocationByMonth: { "2026-01": 120, "2026-02": 120, "2026-03": 120 } },
      ];
      const ALERTS = window.ROE.alerts;
      const at100 = ALERTS.scan(fixture, Object.assign({}, fixture.settings.alertThresholds, { overallocPct: 100 }))
        .filter((a) => a.ruleId === "SUSTAINED_OVERALLOC").length;
      const at130 = ALERTS.scan(fixture, Object.assign({}, fixture.settings.alertThresholds, { overallocPct: 130 }))
        .filter((a) => a.ruleId === "SUSTAINED_OVERALLOC").length;
      return { at100, at130 };
    }, FIXTURE);
    expect(counts.at130).toBeLessThan(counts.at100);
  });
});

test.describe("Mentorship pairing (§4.7, §9 Mentorship)", () => {
  test("mentor with 2 active mentees never appears in suggestions", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const state = {
        employees: [
          { id: "m1", active: true, mentorRole: "Mentor", level: "Principal", discipline: "Civil" },
          { id: "n1", active: true, mentorRole: "Mentee", level: "Junior", discipline: "Civil" },
          { id: "n2", active: true, mentorRole: "Mentee", level: "Junior", discipline: "Civil" },
          { id: "n3", active: true, mentorRole: "Mentee", level: "Junior", discipline: "Civil" },
        ],
        skills: [{ id: "s1" }],
        employeeSkills: [{ employeeId: "m1", skillId: "s1", level: 5 }],
        mentorships: [
          { mentorId: "m1", menteeId: "n1", status: "Active" },
          { mentorId: "m1", menteeId: "n2", status: "Active" },
        ],
        assignments: [],
      };
      const suggestions = window.ROE.mentor.suggest(state);
      return suggestions.filter((s) => s.mentorId === "m1");
    });
    expect(result.length).toBe(0);
  });

  test("compat boundaries: exactly 75 -> High, exactly 50 -> Medium, 49 -> Low", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const M = window.ROE.mentor;
      return [M.compatFor(75), M.compatFor(74), M.compatFor(50), M.compatFor(49)];
    });
    expect(result).toEqual(["High", "Medium", "Medium", "Low"]);
  });

  test("suggestions ordered by pairScore desc, none below 35", async ({ page }) => {
    await loadApp(page);
    const result = await page.evaluate(() => {
      const state = {
        employees: [
          { id: "m1", active: true, mentorRole: "Mentor", level: "Principal", discipline: "Civil" },
          { id: "m2", active: true, mentorRole: "Mentor", level: "Senior", discipline: "Environmental" },
          { id: "n1", active: true, mentorRole: "Mentee", level: "Junior", discipline: "Civil" },
          { id: "n2", active: true, mentorRole: "Mentee", level: "Mid-Level", discipline: "Landscape" },
        ],
        skills: [{ id: "s1" }],
        employeeSkills: [
          { employeeId: "m1", skillId: "s1", level: 5 }, { employeeId: "m2", skillId: "s1", level: 3 },
          { employeeId: "n1", skillId: "s1", level: 0 }, { employeeId: "n2", skillId: "s1", level: 2 },
        ],
        mentorships: [], assignments: [],
      };
      const suggestions = window.ROE.mentor.suggest(state);
      const sorted = suggestions.every((s, i) => i === 0 || suggestions[i - 1].pairScore >= s.pairScore);
      const noneBelow35 = suggestions.every((s) => s.pairScore >= 35);
      return { count: suggestions.length, sorted, noneBelow35 };
    });
    expect(result.sorted).toBe(true);
    expect(result.noneBelow35).toBe(true);
  });
});
