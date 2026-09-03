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

## Program Status Report Builder

A strictly browser-based reporting tool (no server, no backend, no
database) that turns a list of initiatives into an executive-style status
report, and exports it to PDF. Files: `index.html`, `styles.css`, `app.js`,
`sample-data.js`.

### Use it

Open `index.html` directly in a browser (double-click, or serve the folder
with any static file server — e.g. `python3 -m http.server`). All app logic
runs client-side; data is kept only in the browser's local storage and in
files you explicitly export — nothing is uploaded anywhere.

The XLSX import/export/template features load the
[SheetJS](https://sheetjs.com) library, and the Word export loads the
[docx](https://docx.js.org) library, each from a CDN (`cdn.jsdelivr.net`,
with a Subresource Integrity hash pinned in `index.html`), so those specific
buttons need one outbound request on first load. Everything else — the
editor, the report, PDF export, and CSV import/export — works fully offline
even without those requests succeeding; the app detects a failed load and
disables just the affected buttons with an explanatory message.

- **Data Editor** — an editable table of initiatives: Quarter, Strategic
  Pillar, Project Name, Recent Risks and Blockers, Accomplishments/Updates,
  Approximate Completion Percentage, Project Manager, Initiative Description.
  Completion status (Not started / In progress / Gaining momentum) is
  derived automatically from the percentage (0% / 1–24% / 25%+).
- **Report Settings** — program label (eyebrow), quarter, cover title,
  subtitle, program name, an optional mission statement, contact info, and
  an optional "Coming Up" milestones list. Importing a file updates the
  quarter automatically (see below). The hero's overview paragraphs (the
  bold headline plus the sentence about how many initiatives have reached
  25%/50%+ completion) are **not** typed by hand — they're generated live
  from whatever data is currently loaded and recalculate on every edit or
  import.
- **Report Preview** — a landscape executive dashboard: a navy hero band
  (title, quarter/subtitle, dynamic overview paragraphs, contact line, and
  four KPI tiles — Total Initiatives, Active & Underway, Early Wins (50%+),
  Strategic Pillars), a two-card row (Pillar Overview with an inline
  progress bar per pillar plus a Portfolio Status breakdown, and a Coming
  Up milestones timeline), a full-width Quarterly Accomplishments table
  (any initiative with update text), a full-width Quarterly Risks &
  Blockers table (any initiative with risk text), and a second page
  ("Initiative Details by Pillar") with one card per pillar containing a
  compact Initiative / PM / Prog. / Status / Initiative Description table.
  (There is no separate "Early wins" section; the "Early wins (50%+)" KPI
  tile is the only trace of it, in the hero band.)
- **Import CSV / XLSX** — accepts files using the column headers above (a
  handful of common alternate spellings are also recognized). Additive: new
  rows are appended to what's already loaded. The most common non-empty
  "Quarter" value in the imported rows becomes the report's displayed
  quarter (shown in the hero band), overriding whatever was there before.
- **Export CSV / Export XLSX** — download the current initiative list.
- **Download Template (.xlsx / .csv)** — a blank starter workbook with the
  correct headers, one example row, and an Instructions sheet, for others to
  fill in and import back.
- **Export PDF** — opens the browser's print dialog against a print-only
  landscape layout of the report; choose "Save as PDF" (or print) for a
  paginated, vector-quality PDF matching the on-screen report.
- **Export Word (.docx)** — generates a real, editable landscape Word
  document covering the same content and sections as the PDF (hero band as
  a shaded table with nested KPI cells, pillar overview with inline bar
  cells, portfolio status, coming up, Quarterly Accomplishments, Quarterly
  Risks & Blockers, and a page break into an Initiative Details by Pillar
  section with one nested table per pillar) so it can be opened and
  modified directly in Word.
