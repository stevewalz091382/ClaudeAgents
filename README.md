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
report, and exports it as a real, editable Word document. Files:
`index.html`, `styles.css`, `app.js`, `sample-data.js`.

### Use it

Open `index.html` directly in a browser (double-click, or serve the folder
with any static file server — e.g. `python3 -m http.server`). All app logic
runs client-side; data is kept only in the browser's local storage and in
files you explicitly export — nothing is uploaded anywhere.

The XLSX import/export/template features load the
[SheetJS](https://sheetjs.com) library, and the Word export loads the
[docx](https://docx.js.org) library, each from a CDN (`cdn.jsdelivr.net`,
with a Subresource Integrity hash pinned in `index.html`), so those specific
buttons need one outbound request on first load. The editor and CSV
import/export work fully offline even without those requests succeeding;
the app detects a failed load and disables just the affected buttons with
an explanatory message.

- **Data Editor** — an editable table of initiatives: Quarter, Strategic
  Pillar, Project Name, Recent Risks and Blockers, Risk Level (High / Medium
  / Low — defaults to Medium if left blank), Accomplishments/Updates,
  Approximate Completion Percentage, Project Manager, Initiative Description.
  Completion status (Not started / Early stage / In progress / On track) is
  derived automatically from the percentage (0% / 1–24% / 25–74% / 75%+).
- **Report Settings** — program label (eyebrow), quarter, report title,
  subtitle, program name, an optional mission statement, contact info, and
  an optional "Coming Up" milestones list. Importing a file updates the
  quarter automatically (see below). The header's overview paragraphs (the
  bold headline plus the sentences about portfolio completion and risk
  count) are **not** typed by hand — they're generated live from whatever
  data is currently loaded and recalculate on every edit or import.
- **Report Preview** — a preview of the Word export's content: a header
  (title, quarter/subtitle with a live portfolio average, dynamic overview
  paragraphs, contact line), four KPI tiles (Total Initiatives, Active &
  Underway, On Track 75%+, Risks / Blockers), an average-completion-by-pillar
  bar chart (fixed 0–100% axis) alongside a 4-tier portfolio status legend
  (On track / In progress / Early stage / Not started), an "Accomplishments
  & Wins" card grid (any initiative with update text), a "Risks & Blockers"
  table with a colored severity badge per row, an optional "Coming Up"
  milestones table, and a detail table per pillar — Initiative / Project
  Manager / % / Status / Initiative Details — where the Initiative Details
  column shows the description plus an inline orange "Risk:" callout and/or
  green "Win:" callout when that initiative has risk or update text. An
  initiative's name is bolded in its pillar table when it's on track (75%+)
  or is one of the featured wins.
- **Import CSV / XLSX** — accepts files using the column headers above (a
  handful of common alternate spellings are also recognized). Additive: new
  rows are appended to what's already loaded. The most common non-empty
  "Quarter" value in the imported rows becomes the report's displayed
  quarter, overriding whatever was there before.
- **Export CSV / Export XLSX** — download the current initiative list.
- **Download Template (.xlsx / .csv)** — a blank starter workbook with the
  correct headers, one example row, and an Instructions sheet, for others to
  fill in and import back.
- **Export Word (.docx)** — generates a real, editable Word document with
  the same content and sections as the Report Preview (header, KPI tiles,
  bar chart as a shaded table, 4-tier status legend, Accomplishments & Wins
  cards, Risks & Blockers table with severity badges, milestones, and one
  table per pillar — with inline Risk/Win callouts — starting on its own
  page) so it can be opened and modified directly in Word. This is
  currently the tool's only report export format.
