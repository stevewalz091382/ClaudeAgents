---
description: Run the full architect, coder, tester, manager pipeline on an idea
argument-hint: <your idea or feature request>
---

You are orchestrating a four agent build pipeline. The idea is:

$ARGUMENTS

Run the stages below in order. Do not skip a stage. Each stage's output feeds the next. Announce each handoff so I can see where we are.

## Stage 1: Architect
Invoke the architect subagent on the idea above.
The architect asks clarifying questions first. Surface those questions to me and stop. Wait for my answers. Once I answer, have the architect finish BUILD_PLAN.md.
Do not start Stage 2 until BUILD_PLAN.md exists and I have approved it.

## Stage 2: Coder
Invoke the coder subagent to implement BUILD_PLAN.md in order.
Do not start Stage 3 until the coder reports the plan's tasks are implemented and the build runs.

## Stage 3: Tester
Invoke the tester subagent to break the implementation against the plan's acceptance criteria. It writes findings to TEST_REPORT.md, ranked CRITICAL to LOW.

## Stage 4: Manager
Invoke the manager subagent to review the whole chain and return a verdict: GO, GO WITH FIXES, or NO GO.

## Loop
- If the verdict is NO GO or GO WITH FIXES and there are open CRITICAL or HIGH issues, send those specific issues to the coder, then re run the tester and the manager. Repeat at most 3 times.
- If the verdict is GO, or only MEDIUM and LOW issues remain, stop.

## Final report
Give me: what was built mapped to the plan, what the tester found and whether it was fixed, the manager's verdict, and any remaining loose ends.
