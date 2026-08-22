# Four agent build pipeline

A Claude Code pipeline: architect, coder, tester, manager, driven by one `/build` command.

## Contents

    .claude/
      agents/
        architect.md    turns an idea into BUILD_PLAN.md, asks key questions first
        coder.md        implements the plan
        tester.md       breaks the code, writes TEST_REPORT.md
        manager.md      reviews the chain, returns GO / GO WITH FIXES / NO GO
      commands/
        build.md        /build command that runs the whole chain
    CLAUDE.md           context the session loads automatically

## Use on the web

1. Push this folder to a GitHub repo (see below).
2. Open claude.ai/code, connect the repo.
3. Describe the build. The subagents load from `.claude/`, and the manager gates the result.

## Use locally

Copy `.claude/agents/` and `.claude/commands/` into `~/.claude/` (all projects) or a repo's `.claude/` (that project), start `claude`, and run `/build <idea>`.

## Note

Keep `.claude/` out of `.gitignore`. The web session needs these files committed to load them.

## Weighted Decision Engine (`index.html`)

Open `index.html` directly in a browser (double-click it, or `File > Open`) — no server,
build step, or network connection required. It is a single self-contained page for weighing
a decision: define weighted criteria, score options (including a built-in "Do Nothing" status
quo) against them, and get a transparent, ranked recommendation with a per-criterion
contribution breakdown. It also captures the load-bearing assumption behind the decision and
the condition that should trigger a revisit, and can export the result as a Markdown decision
record or a full-session JSON file. Everything is saved to `localStorage` automatically as you
work.

Self-tests for the calculation engine live at `index.html?selftest=1` (also linked from the
page footer, and runnable from the browser console as `window.runSelfTests()`). They exercise
weight normalization, direction inversion, unscored-cell handling, multi-rater aggregation,
ranking/ties, the close-call threshold, export gating, and JSON import/migration safety,
independent of the UI.
