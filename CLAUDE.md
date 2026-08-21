# Four agent build pipeline

This repo carries a Claude Code build pipeline. Four subagents in `.claude/agents/` and one command in `.claude/commands/` turn an idea into reviewed code.

## Agents

- **architect**: turns an idea into `BUILD_PLAN.md`, asking the key questions first. Writes no production code.
- **coder**: implements `BUILD_PLAN.md` in order.
- **tester**: tries to break the implementation and writes `TEST_REPORT.md`, ranked CRITICAL to LOW.
- **manager**: reviews the whole chain and returns GO, GO WITH FIXES, or NO GO.

## Run

Use `/build <idea>` to run the full chain. The orchestrator invokes each agent in order, passes `BUILD_PLAN.md`, the implementation, and `TEST_REPORT.md` between stages, and loops CRITICAL or HIGH fixes back to the coder up to three times.

## Human gate

Stage 1 pauses for you to answer the architect's questions and approve the plan before any code is written.
