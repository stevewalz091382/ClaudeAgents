(function () {
  'use strict';

  // ---------------------------------------------------------------------
  // Schema
  // ---------------------------------------------------------------------
  const COLUMNS = ['quarter', 'pillar', 'project', 'risks', 'updates', 'pct', 'pm', 'description'];
  const HEADERS = {
    quarter: 'Quarter',
    pillar: 'Strategic Pillar',
    project: 'Project Name',
    risks: 'Recent Risks and Blockers',
    updates: 'Accomplishments/Updates',
    pct: 'Approximate Completion Percentage',
    pm: 'Project Manager',
    description: 'Initiative Description'
  };
  // Accepted alternate header spellings on import, normalized (lowercase, alnum only) -> internal key
  const HEADER_ALIASES = {
    quarter: 'quarter',
    period: 'quarter',
    reportingperiod: 'quarter',
    strategicpillar: 'pillar',
    pillar: 'pillar',
    projectname: 'project',
    project: 'project',
    initiative: 'project',
    initiativename: 'project',
    recentrisksandblockers: 'risks',
    risksandblockers: 'risks',
    risksblockers: 'risks',
    risks: 'risks',
    blockers: 'risks',
    accomplishmentsupdates: 'updates',
    accomplishments: 'updates',
    updates: 'updates',
    keyupdate: 'updates',
    status: 'updates',
    approximatecompletionpercentage: 'pct',
    completionpercentage: 'pct',
    approxcompletion: 'pct',
    completion: 'pct',
    pctcomplete: 'pct',
    percentcomplete: 'pct',
    percentage: 'pct',
    pct: 'pct',
    projectmanager: 'pm',
    pm: 'pm',
    owner: 'pm',
    manager: 'pm',
    initiativedescription: 'description',
    description: 'description'
  };

  const PILLAR_ORDER = [
    'Digital Platforms', 'Data', 'Technology Innovation',
    'Quality', 'Execution & Delivery', 'Implementation'
  ];
  // Exact hex values extracted from the reference report's PDF (text + fill colors).
  const PILLAR_COLORS = {
    'Digital Platforms': '#185fa5',
    'Data': '#0f6e56',
    'Technology Innovation': '#534ab7',
    'Quality': '#993c1d',
    'Execution & Delivery': '#ba7517',
    'Implementation': '#5f5e5a'
  };
  const PILLAR_TINTS = {
    'Digital Platforms': '#ddeaf7',
    'Data': '#d6efe6',
    'Technology Innovation': '#e3e1f4',
    'Quality': '#f1ddd5',
    'Execution & Delivery': '#f5ead5',
    'Implementation': '#e7e7e5'
  };
  const FALLBACK_PALETTE = ['#0891b2', '#be185d', '#4d7c0f', '#a16207', '#334155', '#7c2d12', '#0f766e', '#b91c1c'];
  const FALLBACK_TINT_PALETTE = ['#d9eef2', '#fbe1ec', '#e6efd8', '#f4e9d3', '#dee1e6', '#f1ddd0', '#d7ece7', '#f7dcdc'];

  const STORAGE_KEY = 'reportBuilder.v1';
  // "Early wins" highlight threshold — deliberately separate from the
  // "Gaining momentum" status threshold (25%) used elsewhere in the report.
  const EARLY_WIN_THRESHOLD = 50;

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  let nextId = 1;
  let state = {
    rows: [],
    milestones: [],
    settings: {
      eyebrow: 'PROGRAM STATUS UPDATE',
      quarter: '',
      title: 'Program & Strategy Update',
      subtitle: 'Executive Leadership Summary',
      programName: '',
      missionText: '',
      contactName: '',
      contactEmail: '',
      milestonesTitle: 'Coming Up',
      milestonesIntro: ''
    }
  };

  function newRow(data) {
    return {
      id: 'r' + (nextId++),
      quarter: (data && data.quarter) || '',
      pillar: (data && data.pillar) || '',
      project: (data && data.project) || '',
      risks: (data && data.risks) || '',
      updates: (data && data.updates) || '',
      pct: data && data.pct != null && data.pct !== '' ? clampPct(data.pct) : 0,
      pm: (data && data.pm) || '',
      description: (data && data.description) || ''
    };
  }

  function eyebrowText() {
    const base = (state.settings.eyebrow || '').trim();
    const q = (state.settings.quarter || '').trim();
    if (base && q) return `${base} · ${q}`;
    return base || q;
  }

  // Builds the cover's overview paragraphs live from the current dataset —
  // recomputed on every render so it always reflects whatever is loaded,
  // instead of being hand-typed text that goes stale after a new import.
  // Returns an array of { lead, text }; the first paragraph (lead: true) is
  // the bold headline sentence, the rest render as regular paragraphs.
  function buildOverviewParagraphs(agg) {
    const paras = [];
    const programName = (state.settings.programName || '').trim() || 'program';
    const quarter = (state.settings.quarter || '').trim();

    if (agg.total > 0) {
      const opening = quarter ? `${quarter} is proving` : 'This period is proving';
      paras.push({ lead: true, text: `${opening} to be a period of real, tangible momentum for the ${programName}.` });

      const pillarCount = agg.pillarCount;
      const momentum = agg.statusCounts.momentum;
      const highTier = agg.earlyWins;
      let sentence = `Across all ${pillarCount} strategic pillar${pillarCount === 1 ? '' : 's'}, our teams have moved quickly from planning into delivery.`;
      sentence += ` ${momentum} of ${agg.total} initiative${agg.total === 1 ? '' : 's'} ${momentum === 1 ? 'has' : 'have'} already reached 25% or greater completion`;
      sentence += highTier > 0 ? ` — ${highTier} of them tracking at ${EARLY_WIN_THRESHOLD}%+.` : '.';
      paras.push({ lead: false, text: sentence });
    }

    const mission = (state.settings.missionText || '').trim();
    if (mission) paras.push({ lead: false, text: mission });

    return paras;
  }

  function clampPct(v) {
    let n = typeof v === 'number' ? v : parseFloat(String(v).replace('%', '').trim());
    if (isNaN(n)) return 0;
    if (n <= 1 && n > 0 && String(v).indexOf('%') === -1 && String(v).indexOf('.') !== -1) {
      // heuristic: a bare decimal like 0.35 from a spreadsheet percentage cell means 35%
      n = n * 100;
    }
    if (n < 0) n = 0;
    if (n > 100) n = 100;
    return Math.round(n * 10) / 10;
  }

  function statusFor(pct) {
    if (pct >= 25) return { label: 'Gaining momentum', cls: 'status-momentum' };
    if (pct >= 1) return { label: 'In progress', cls: 'status-progress' };
    return { label: 'Not started', cls: 'status-none' };
  }

  function pillarColor(pillar, indexHint) {
    if (PILLAR_COLORS[pillar]) return PILLAR_COLORS[pillar];
    const extra = getExtraPillars();
    const idx = extra.indexOf(pillar);
    return FALLBACK_PALETTE[(idx >= 0 ? idx : (indexHint || 0)) % FALLBACK_PALETTE.length];
  }

  function pillarTint(pillar, indexHint) {
    if (PILLAR_TINTS[pillar]) return PILLAR_TINTS[pillar];
    const extra = getExtraPillars();
    const idx = extra.indexOf(pillar);
    return FALLBACK_TINT_PALETTE[(idx >= 0 ? idx : (indexHint || 0)) % FALLBACK_TINT_PALETTE.length];
  }

  // Avg-completion tier color used only in the Pillar Overview table, matching
  // the reference report: <10% gray, 10-19% blue, >=20% green.
  function avgTierColor(avg) {
    if (avg >= 20) return '#0f6e56';
    if (avg >= 10) return '#185fa5';
    return '#888888';
  }

  function getExtraPillars() {
    const set = new Set();
    state.rows.forEach(r => { if (r.pillar && PILLAR_ORDER.indexOf(r.pillar) === -1) set.add(r.pillar); });
    return Array.from(set).sort();
  }

  function orderedPillars() {
    const present = new Set(state.rows.map(r => r.pillar).filter(Boolean));
    const known = PILLAR_ORDER.filter(p => present.has(p));
    const extra = getExtraPillars().filter(p => present.has(p));
    return known.concat(extra);
  }

  // ---------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------
  function save() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ rows: state.rows, milestones: state.milestones, settings: state.settings }));
    } catch (e) { /* storage unavailable — non-fatal */ }
  }

  function load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return false;
      const parsed = JSON.parse(raw);
      if (parsed && Array.isArray(parsed.rows)) {
        state.rows = parsed.rows.map(r => newRow(r));
        state.milestones = Array.isArray(parsed.milestones) ? parsed.milestones : [];
        state.settings = Object.assign({}, state.settings, parsed.settings || {});
        return true;
      }
    } catch (e) { /* ignore corrupt storage */ }
    return false;
  }

  // ---------------------------------------------------------------------
  // CSV
  // ---------------------------------------------------------------------
  function parseCSV(text) {
    const rows = [];
    let row = [], field = '', inQuotes = false;
    text = text.replace(/^﻿/, ''); // strip BOM
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (inQuotes) {
        if (c === '"') {
          if (text[i + 1] === '"') { field += '"'; i++; }
          else { inQuotes = false; }
        } else {
          field += c;
        }
      } else {
        if (c === '"') { inQuotes = true; }
        else if (c === ',') { row.push(field); field = ''; }
        else if (c === '\r') { /* skip, \n handles the break */ }
        else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
        else { field += c; }
      }
    }
    // last field/row
    if (field.length || row.length) { row.push(field); rows.push(row); }
    return rows.filter(r => !(r.length === 1 && r[0] === ''));
  }

  function csvField(v) {
    const s = v == null ? '' : String(v);
    if (/[",\n\r]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
  }

  function rowsToCSV(rows) {
    const lines = [COLUMNS.map(c => csvField(HEADERS[c])).join(',')];
    rows.forEach(r => {
      lines.push(COLUMNS.map(c => csvField(c === 'pct' ? r.pct : r[c])).join(','));
    });
    return lines.join('\r\n');
  }

  function mapHeaderRow(headerRow) {
    return headerRow.map(h => {
      const norm = String(h || '').toLowerCase().replace(/[^a-z0-9]/g, '');
      return HEADER_ALIASES[norm] || null;
    });
  }

  function recordsFromTable(headerRow, dataRows) {
    const keys = mapHeaderRow(headerRow);
    const out = [];
    dataRows.forEach(r => {
      if (!r.some(v => String(v || '').trim() !== '')) return; // skip blank rows
      const obj = {};
      keys.forEach((k, i) => { if (k) obj[k] = r[i]; });
      if (!obj.project && !obj.pillar && !obj.description) return; // skip rows we can't use
      out.push(newRow(obj));
    });
    return out;
  }

  function importCSVText(text) {
    const table = parseCSV(text);
    if (!table.length) throw new Error('The CSV file is empty.');
    const [header, ...rest] = table;
    const mapped = mapHeaderRow(header);
    if (!mapped.includes('project') && !mapped.includes('pillar')) {
      throw new Error('Could not find recognizable column headers (expected columns like "Quarter", "Strategic Pillar", "Project Name", "Recent Risks and Blockers", "Accomplishments/Updates", "Approximate Completion Percentage", "Project Manager", "Initiative Description").');
    }
    return recordsFromTable(header, rest);
  }

  // ---------------------------------------------------------------------
  // XLSX (SheetJS)
  // ---------------------------------------------------------------------
  function importXLSXArrayBuffer(buf) {
    const wb = XLSX.read(buf, { type: 'array' });
    const sheetName = wb.SheetNames.find(n => !/instructions/i.test(n)) || wb.SheetNames[0];
    const sheet = wb.Sheets[sheetName];
    const table = XLSX.utils.sheet_to_json(sheet, { header: 1, blankrows: false, raw: true });
    if (!table.length) throw new Error('The workbook has no data.');
    const [header, ...rest] = table;
    const mapped = mapHeaderRow(header);
    if (!mapped.includes('project') && !mapped.includes('pillar')) {
      throw new Error('Could not find recognizable column headers in the first sheet.');
    }
    return recordsFromTable(header, rest);
  }

  function buildWorkbookFromRows(rows) {
    const aoa = [COLUMNS.map(c => HEADERS[c])];
    rows.forEach(r => aoa.push(COLUMNS.map(c => c === 'pct' ? r.pct : r[c])));
    const sheet = XLSX.utils.aoa_to_sheet(aoa);
    sheet['!cols'] = [{ wch: 10 }, { wch: 22 }, { wch: 28 }, { wch: 40 }, { wch: 40 }, { wch: 14 }, { wch: 18 }, { wch: 40 }];
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, sheet, 'Initiatives');
    return wb;
  }

  function buildTemplateWorkbook() {
    const example = newRow({
      quarter: 'Q3 2026',
      pillar: 'Digital Platforms',
      project: 'Example Initiative Name',
      risks: 'Any current risk, blocker, or dependency putting this initiative at risk (leave blank if none).',
      updates: 'Short narrative of what happened this period: milestones hit, blockers, next steps.',
      pct: 25,
      pm: 'Full Name',
      description: 'One or two sentences describing the goal/scope of this initiative.'
    });
    const wb = buildWorkbookFromRows([example]);
    const instructions = XLSX.utils.aoa_to_sheet([
      ['How to use this template'],
      [''],
      ['1. Keep the header row on the "Initiatives" sheet exactly as provided.'],
      ['2. One row per initiative. Delete the example row before adding your own.'],
      ['3. "Quarter" is the reporting period (e.g. "Q3 2026"). Use the same value for every row in one' +
        ' import — the report header updates automatically to the quarter found in the file you import.'],
      ['4. "Approximate Completion Percentage" is a number from 0-100 (do not include the % sign).'],
      ['5. "Strategic Pillar" groups initiatives in the report. Use a consistent name per pillar' +
        ' (e.g. Digital Platforms, Data, Technology Innovation, Quality, Execution & Delivery, Implementation)' +
        ' — or your own pillar names.'],
      ['6. "Recent Risks and Blockers" is optional — leave blank if there is nothing to flag. Any row with' +
        ' text here appears in the report’s "Risks & Blockers" section.'],
      ['7. "Accomplishments/Updates" is optional — any row with text here appears in the report’s' +
        ' "Accomplishments" section.'],
      ['8. Save as .xlsx or .csv and import it back into the Report Builder using "Import CSV / XLSX".'],
      ['9. Completion status shown per initiative (Not started / In progress / Gaining momentum) is' +
        ' calculated automatically: 0% = Not started, 1-24% = In progress, 25%+ = Gaining momentum. The' +
        ' report’s separate "Early wins" highlight uses a higher bar: 50%+.']
    ]);
    instructions['!cols'] = [{ wch: 100 }];
    XLSX.utils.book_append_sheet(wb, instructions, 'Instructions');
    return wb;
  }

  // ---------------------------------------------------------------------
  // Word (.docx) export
  // ---------------------------------------------------------------------
  function hex6(c) { return String(c || '000000').replace('#', '').toUpperCase(); }

  function buildWordDocument() {
    const {
      Document, Paragraph, TextRun, Table, TableRow, TableCell, AlignmentType,
      WidthType, BorderStyle, ShadingType, VerticalAlign, convertInchesToTwip
    } = docx;

    const NO_BORDERS = {
      top: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' },
      bottom: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' },
      left: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' },
      right: { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' }
    };

    function run(text, opts) {
      opts = opts || {};
      return new TextRun({
        text: text == null ? '' : String(text),
        bold: !!opts.bold,
        italics: !!opts.italics,
        color: opts.color ? hex6(opts.color) : undefined,
        size: opts.size || 16,
        font: opts.font || 'Arial'
      });
    }
    function p(textOrRuns, opts) {
      opts = opts || {};
      return new Paragraph({
        children: typeof textOrRuns === 'string' ? [run(textOrRuns, opts)] : textOrRuns,
        alignment: opts.align,
        spacing: { before: opts.before || 0, after: opts.after != null ? opts.after : 60 },
        pageBreakBefore: !!opts.pageBreakBefore
      });
    }
    function cell(children, opts) {
      opts = opts || {};
      return new TableCell({
        children: Array.isArray(children) ? children : [children],
        width: opts.width != null ? { size: opts.width, type: WidthType.PERCENTAGE } : undefined,
        shading: opts.fill ? { fill: hex6(opts.fill), type: ShadingType.CLEAR, color: 'auto' } : undefined,
        borders: opts.noBorder ? NO_BORDERS : undefined,
        margins: { top: 60, bottom: 60, left: 100, right: 100 },
        verticalAlign: VerticalAlign.CENTER
      });
    }
    function fullTable(rows, opts) {
      return new Table({
        width: { size: 100, type: WidthType.PERCENTAGE },
        rows,
        borders: (opts && opts.noBorder) ? NO_BORDERS : undefined
      });
    }

    const agg = computeAggregates();
    const children = [];

    // ---- Cover ----
    children.push(p(eyebrowText(), { size: 15, color: '888888', bold: true, after: 40 }));
    children.push(new Paragraph({
      children: [run(state.settings.title || 'Program & Strategy Update', { bold: true, size: 36, color: '1F3864', font: 'Georgia' })],
      spacing: { after: 40 }
    }));
    children.push(p(state.settings.subtitle || '', { size: 18, color: '666666', after: 200 }));

    const overviewParas = buildOverviewParagraphs(agg);
    if (overviewParas.length || state.settings.contactEmail) {
      overviewParas.forEach((para, i) => {
        children.push(new Paragraph({
          shading: { fill: 'F0F5FB', type: ShadingType.CLEAR, color: 'auto' },
          border: i === 0 ? { left: { style: BorderStyle.SINGLE, size: 24, color: '185FA5' } } : undefined,
          children: [run(para.text, { bold: para.lead, color: para.lead ? '1F3864' : '333333', size: para.lead ? 18 : 16 })],
          spacing: { before: i === 0 ? 100 : 0, after: 60 }
        }));
      });
      if (state.settings.contactName || state.settings.contactEmail) {
        const parts = [run('Questions or follow-up? Contact ', { color: '555555', size: 16 })];
        if (state.settings.contactEmail) parts.push(run(state.settings.contactEmail, { bold: true, color: '185FA5', size: 16 }));
        if (state.settings.contactName) parts.push(run(state.settings.contactEmail ? ` (${state.settings.contactName})` : state.settings.contactName, { color: '555555', size: 16 }));
        parts.push(run(' directly.', { color: '555555', size: 16 }));
        children.push(new Paragraph({ shading: { fill: 'F0F5FB', type: ShadingType.CLEAR, color: 'auto' }, children: parts, spacing: { after: 200 } }));
      }
    }

    children.push(p('Portfolio at a Glance', { bold: true, color: '1F3864', size: 22, after: 120 }));

    // KPI tiles
    const kpiVals = [
      [agg.total, 'Total initiatives', '1F3864'],
      [agg.active, 'Active & underway', '185FA5'],
      [agg.earlyWins, `Early wins (${EARLY_WIN_THRESHOLD}%+)`, '0F6E56'],
      [agg.pillarCount, 'Strategic pillars', '1F3864']
    ];
    children.push(fullTable([new TableRow({
      children: kpiVals.map(([num, label, color]) => cell([
        p(String(num), { bold: true, size: 36, color, align: AlignmentType.CENTER, after: 20 }),
        p(label, { size: 14, color: '777777', align: AlignmentType.CENTER, after: 0 })
      ], { width: 25, fill: 'F4F6FA' }))
    })]));

    children.push(p('', { after: 160 }));

    // Average completion by pillar (as a table with shaded "bar" cells)
    children.push(p('AVERAGE COMPLETION BY PILLAR', { bold: true, size: 14, color: '888888', after: 100 }));
    const maxAvg = Math.max(25, ...agg.byPillar.map(x => x.avg));
    const barRows = agg.byPillar.map(x => {
      const pct = Math.max(2, Math.min(100, Math.round((x.avg / maxAvg) * 100)));
      const barInner = new Table({
        width: { size: 100, type: WidthType.PERCENTAGE },
        borders: NO_BORDERS,
        rows: [new TableRow({
          children: [
            cell(p(''), { width: pct, fill: x.color, noBorder: true }),
            cell(p(''), { width: Math.max(1, 100 - pct), fill: 'F0F2F5', noBorder: true })
          ]
        })]
      });
      return new TableRow({ children: [
        cell(p(x.pillar, { bold: true, color: x.color, size: 15 }), { width: 25, noBorder: true }),
        cell(barInner, { width: 60, noBorder: true }),
        cell(p(fmtPct(x.avg), { bold: true, size: 15, align: AlignmentType.RIGHT }), { width: 15, noBorder: true })
      ] });
    });
    children.push(fullTable(barRows, { noBorder: true }));

    children.push(p('', { after: 160 }));

    // Portfolio status
    children.push(p('PORTFOLIO STATUS', { bold: true, size: 14, color: '888888', after: 100 }));
    const sc = agg.statusCounts;
    const statusRows = [
      ['Gaining momentum (25%+)', sc.momentum, '1D9E75'],
      ['Early stage (1–24%)', sc.progress, '378ADD'],
      ['Not started', sc.none, 'CCCCCC']
    ].map(([label, count, color]) => new TableRow({ children: [
      cell(p(''), { width: 6, fill: color, noBorder: true }),
      cell(p(`${label}: ${count}`, { size: 15 }), { width: 94, noBorder: true })
    ] }));
    children.push(fullTable(statusRows, { noBorder: true }));

    children.push(p('', { after: 160 }));

    // Pillar overview table
    children.push(p('Pillar Overview', { bold: true, color: '1F3864', size: 22, after: 120 }));
    const overviewHeader = new TableRow({ children: [
      cell(p('Pillar', { bold: true, color: 'FFFFFF' }), { width: 20, fill: '1F3864' }),
      cell(p('Count', { bold: true, color: 'FFFFFF' }), { width: 10, fill: '1F3864' }),
      cell(p('Avg %', { bold: true, color: 'FFFFFF' }), { width: 11, fill: '1F3864' }),
      cell(p('Top performing initiative', { bold: true, color: 'FFFFFF' }), { width: 59, fill: '1F3864' })
    ] });
    const overviewRows = agg.byPillar.map(x => new TableRow({ children: [
      cell(p(x.pillar, { bold: true, color: x.color }), { width: 20, fill: pillarTint(x.pillar) }),
      cell(p(String(x.count)), { width: 10 }),
      cell(p(fmtPct(x.avg), { bold: true, color: avgTierColor(x.avg) }), { width: 11 }),
      cell(p(x.top ? `${x.top.project} — ${fmtPct(x.top.pct)}` : '—'), { width: 59 })
    ] }));
    children.push(fullTable([overviewHeader].concat(overviewRows)));

    // Accomplishments (cross-pillar roundup of reported updates)
    const accomplishmentRows = state.rows.filter(r => (r.updates || '').trim());
    if (accomplishmentRows.length) {
      children.push(p('Quarterly Accomplishments', { bold: true, color: '1F3864', size: 22, before: 300, after: 120 }));
      const aHeader = new TableRow({ children: [
        cell(p('Initiative', { bold: true, color: 'FFFFFF' }), { width: 26, fill: '1F3864' }),
        cell(p('Pillar', { bold: true, color: 'FFFFFF' }), { width: 18, fill: '1F3864' }),
        cell(p('Accomplishment', { bold: true, color: 'FFFFFF' }), { width: 56, fill: '1F3864' })
      ] });
      const aRows = accomplishmentRows.map(r => new TableRow({ children: [
        cell(p(r.project, { bold: true })),
        cell(p(r.pillar, { color: pillarColor(r.pillar) })),
        cell(p(r.updates, { color: '555555' }))
      ] }));
      children.push(fullTable([aHeader].concat(aRows)));
    }

    // Risks & Blockers (cross-pillar roundup)
    const riskRows = state.rows.filter(r => (r.risks || '').trim());
    if (riskRows.length) {
      children.push(p('Quarterly Risks & Blockers', { bold: true, color: '1F3864', size: 22, before: 300, after: 120 }));
      const rHeader = new TableRow({ children: [
        cell(p('Initiative', { bold: true, color: 'FFFFFF' }), { width: 22, fill: '993C1D' }),
        cell(p('Pillar', { bold: true, color: 'FFFFFF' }), { width: 14, fill: '993C1D' }),
        cell(p('Project Manager', { bold: true, color: 'FFFFFF' }), { width: 14, fill: '993C1D' }),
        cell(p('Risk / Blocker', { bold: true, color: 'FFFFFF' }), { width: 50, fill: '993C1D' })
      ] });
      const rRows = riskRows.map(r => new TableRow({ children: [
        cell(p(r.project, { bold: true })),
        cell(p(r.pillar, { color: pillarColor(r.pillar) })),
        cell(p(r.pm || '—', { color: '555555' })),
        cell(p(r.risks, { color: '555555' }))
      ] }));
      children.push(fullTable([rHeader].concat(rRows)));
    }

    // Coming up / milestones
    const milestoneRows = state.milestones.filter(m => m.when || m.text);
    if (milestoneRows.length) {
      children.push(p(state.settings.milestonesTitle || 'Coming Up', { bold: true, color: '1F3864', size: 22, before: 300, after: 80 }));
      if (state.settings.milestonesIntro) children.push(p(state.settings.milestonesIntro, { color: '555555', size: 16, after: 120 }));
      const mRows = milestoneRows.map(m => new TableRow({ children: [
        cell(p(m.when || '', { bold: true, color: '185FA5' }), { width: 20 }),
        cell(p(m.text || ''), { width: 80 })
      ] }));
      children.push(fullTable(mRows));
    }

    // Per-pillar detail tables (each starts on a fresh page)
    agg.pillars.forEach(pillar => {
      const items = state.rows.filter(r => r.pillar === pillar);
      if (!items.length) return;
      const pAgg = agg.byPillar.find(x => x.pillar === pillar);
      children.push(new Paragraph({
        children: [
          run(pillar, { bold: true, color: pAgg.color, size: 22 }),
          run(`   |   ${items.length} initiative${items.length === 1 ? '' : 's'} · ${fmtPct(pAgg.avg)} avg completion`, { color: '888888', size: 15 })
        ],
        spacing: { before: 0, after: 120 },
        pageBreakBefore: true
      }));
      const dHeader = new TableRow({ children: [
        cell(p('Initiative', { bold: true, color: 'FFFFFF' }), { width: 26, fill: pAgg.color }),
        cell(p('Project Manager', { bold: true, color: 'FFFFFF' }), { width: 13, fill: pAgg.color }),
        cell(p('%', { bold: true, color: 'FFFFFF' }), { width: 7, fill: pAgg.color }),
        cell(p('Status', { bold: true, color: 'FFFFFF' }), { width: 18, fill: pAgg.color }),
        cell(p('Initiative Description', { bold: true, color: 'FFFFFF' }), { width: 36, fill: pAgg.color })
      ] });
      const dRows = items.map(r => {
        const s = statusFor(r.pct);
        const statusColor = s.cls === 'status-momentum' ? '0F6E56' : (s.cls === 'status-progress' ? '185FA5' : '999999');
        return new TableRow({ children: [
          cell(p(r.project, { bold: s.cls === 'status-momentum' })),
          cell(p(r.pm || '—', { color: '555555' })),
          cell(p(fmtPct(r.pct), { bold: true })),
          cell(p(s.label, { bold: true, color: statusColor, size: 15 })),
          cell(p(r.description || '—', { color: '555555' }))
        ] });
      });
      children.push(fullTable([dHeader].concat(dRows)));
    });

    return new Document({
      sections: [{
        properties: {
          page: {
            size: { width: convertInchesToTwip(8.5), height: convertInchesToTwip(11) },
            margin: {
              top: convertInchesToTwip(0.56), bottom: convertInchesToTwip(0.56),
              left: convertInchesToTwip(0.56), right: convertInchesToTwip(0.56)
            }
          }
        },
        children
      }]
    });
  }

  // ---------------------------------------------------------------------
  // File download helpers
  // ---------------------------------------------------------------------
  function downloadBlob(filename, blob) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function downloadCSV(filename, csvText) {
    downloadBlob(filename, new Blob(['﻿' + csvText], { type: 'text/csv;charset=utf-8;' }));
  }

  function downloadXLSX(filename, wb) {
    XLSX.writeFile(wb, filename);
  }

  function timestamp() {
    const d = new Date();
    const p = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`;
  }

  // ---------------------------------------------------------------------
  // Import status banner
  // ---------------------------------------------------------------------
  let importStatusTimer = null;
  function showImportStatus(message, isError) {
    const el = document.getElementById('importStatus');
    el.textContent = message;
    el.hidden = false;
    el.className = 'import-status no-print' + (isError ? ' error' : ' success');
    clearTimeout(importStatusTimer);
    importStatusTimer = setTimeout(() => { el.hidden = true; }, 6000);
  }

  // ---------------------------------------------------------------------
  // Editor rendering
  // ---------------------------------------------------------------------
  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(k => {
      if (k === 'class') node.className = attrs[k];
      else if (k === 'text') node.textContent = attrs[k];
      else node.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(c => node.appendChild(c));
    return node;
  }

  function renderEditor() {
    const body = document.getElementById('editorBody');
    body.innerHTML = '';
    if (!state.rows.length) {
      const tr = el('tr', {}, [el('td', { colspan: '9', class: 'empty-row', text: 'No initiatives yet. Add one, import a file, or load sample data.' })]);
      body.appendChild(tr);
      return;
    }
    state.rows.forEach(row => {
      const tr = el('tr', { 'data-id': row.id });

      const quarterInput = el('input', { type: 'text', value: row.quarter, 'data-field': 'quarter' });
      const pillarInput = el('input', { type: 'text', value: row.pillar, list: 'pillarSuggestions', 'data-field': 'pillar' });
      const projectInput = el('input', { type: 'text', value: row.project, 'data-field': 'project' });
      const risksInput = el('textarea', { rows: '2', 'data-field': 'risks' });
      risksInput.value = row.risks;
      const updatesInput = el('textarea', { rows: '2', 'data-field': 'updates' });
      updatesInput.value = row.updates;
      const pctInput = el('input', { type: 'number', min: '0', max: '100', step: '1', value: String(row.pct), 'data-field': 'pct' });
      const pmInput = el('input', { type: 'text', value: row.pm, 'data-field': 'pm' });
      const descInput = el('textarea', { rows: '2', 'data-field': 'description' });
      descInput.value = row.description;

      [quarterInput, pillarInput, projectInput, risksInput, updatesInput, pctInput, pmInput, descInput].forEach(inp => {
        inp.addEventListener('input', () => {
          const field = inp.getAttribute('data-field');
          row[field] = field === 'pct' ? clampPct(inp.value) : inp.value;
          save();
          renderReport();
          renderPillarDatalist();
        });
      });

      const delBtn = el('button', { class: 'btn-icon-del', title: 'Delete row', text: '✕' });
      delBtn.addEventListener('click', () => {
        state.rows = state.rows.filter(r => r.id !== row.id);
        save();
        renderEditor();
        renderReport();
      });

      tr.appendChild(el('td', {}, [quarterInput]));
      tr.appendChild(el('td', {}, [pillarInput]));
      tr.appendChild(el('td', {}, [projectInput]));
      tr.appendChild(el('td', {}, [risksInput]));
      tr.appendChild(el('td', {}, [updatesInput]));
      tr.appendChild(el('td', {}, [pctInput]));
      tr.appendChild(el('td', {}, [pmInput]));
      tr.appendChild(el('td', {}, [descInput]));
      tr.appendChild(el('td', {}, [delBtn]));
      body.appendChild(tr);
    });
  }

  function renderPillarDatalist() {
    let dl = document.getElementById('pillarSuggestions');
    if (!dl) {
      dl = document.createElement('datalist');
      dl.id = 'pillarSuggestions';
      document.body.appendChild(dl);
    }
    const all = PILLAR_ORDER.concat(getExtraPillars());
    dl.innerHTML = '';
    all.forEach(p => dl.appendChild(el('option', { value: p })));
  }

  function renderMilestones() {
    const body = document.getElementById('milestoneBody');
    body.innerHTML = '';
    if (!state.milestones.length) {
      body.appendChild(el('tr', {}, [el('td', { colspan: '3', class: 'empty-row', text: 'No milestones added.' })]));
      return;
    }
    state.milestones.forEach((m, idx) => {
      const tr = el('tr');
      const whenInput = el('input', { type: 'text', value: m.when || '' });
      const textInput = el('input', { type: 'text', value: m.text || '' });
      whenInput.addEventListener('input', () => { m.when = whenInput.value; save(); renderReport(); });
      textInput.addEventListener('input', () => { m.text = textInput.value; save(); renderReport(); });
      const delBtn = el('button', { class: 'btn-icon-del', title: 'Remove', text: '✕' });
      delBtn.addEventListener('click', () => {
        state.milestones.splice(idx, 1);
        save();
        renderMilestones();
        renderReport();
      });
      tr.appendChild(el('td', {}, [whenInput]));
      tr.appendChild(el('td', {}, [textInput]));
      tr.appendChild(el('td', {}, [delBtn]));
      body.appendChild(tr);
    });
  }

  function renderSettingsForm() {
    document.getElementById('setEyebrow').value = state.settings.eyebrow || '';
    document.getElementById('setQuarter').value = state.settings.quarter || '';
    document.getElementById('setTitle').value = state.settings.title || '';
    document.getElementById('setSubtitle').value = state.settings.subtitle || '';
    document.getElementById('setProgramName').value = state.settings.programName || '';
    document.getElementById('setMissionText').value = state.settings.missionText || '';
    document.getElementById('setContactName').value = state.settings.contactName || '';
    document.getElementById('setContactEmail').value = state.settings.contactEmail || '';
    document.getElementById('setMilestonesTitle').value = state.settings.milestonesTitle || '';
    document.getElementById('setMilestonesIntro').value = state.settings.milestonesIntro || '';
  }

  function wireSettingsForm() {
    const map = {
      setEyebrow: 'eyebrow', setQuarter: 'quarter', setTitle: 'title', setSubtitle: 'subtitle',
      setProgramName: 'programName', setMissionText: 'missionText',
      setContactName: 'contactName', setContactEmail: 'contactEmail',
      setMilestonesTitle: 'milestonesTitle', setMilestonesIntro: 'milestonesIntro'
    };
    Object.keys(map).forEach(id => {
      document.getElementById(id).addEventListener('input', (e) => {
        state.settings[map[id]] = e.target.value;
        save();
        renderReport();
      });
    });
  }

  // ---------------------------------------------------------------------
  // Aggregates
  // ---------------------------------------------------------------------
  function computeAggregates() {
    const rows = state.rows;
    const total = rows.length;
    const active = rows.filter(r => r.pct > 0).length;
    const earlyWins = rows.filter(r => r.pct >= EARLY_WIN_THRESHOLD).length;
    const pillars = orderedPillars();

    const byPillar = pillars.map(p => {
      const items = rows.filter(r => r.pillar === p);
      const avg = items.length ? items.reduce((s, r) => s + r.pct, 0) / items.length : 0;
      const top = items.slice().sort((a, b) => b.pct - a.pct)[0];
      return { pillar: p, count: items.length, avg: Math.round(avg * 10) / 10, top, color: pillarColor(p) };
    });

    const statusCounts = { momentum: 0, progress: 0, none: 0 };
    rows.forEach(r => {
      const s = statusFor(r.pct);
      if (s.cls === 'status-momentum') statusCounts.momentum++;
      else if (s.cls === 'status-progress') statusCounts.progress++;
      else statusCounts.none++;
    });

    return { total, active, earlyWins, pillarCount: pillars.length, byPillar, statusCounts, pillars };
  }

  // ---------------------------------------------------------------------
  // Report rendering
  // ---------------------------------------------------------------------
  function fmtPct(n) { return `${n}%`; }

  // Fixed KPI tile accent colors, left to right, matching the reference report.
  const KPI_COLORS = ['#1f3864', '#185fa5', '#0f6e56', '#1f3864'];
  const DONUT_COLORS = { momentum: '#1d9e75', progress: '#378add', none: '#cccccc' };

  function renderReport() {
    const root = document.getElementById('reportRoot');
    root.innerHTML = '';
    const agg = computeAggregates();

    // ---- Cover / summary section (always starts its own printed page) ----
    const cover = el('section', { class: 'r-page r-cover' });
    cover.appendChild(el('div', { class: 'r-eyebrow', text: eyebrowText() }));
    cover.appendChild(el('h1', { class: 'r-title', text: state.settings.title || 'Program & Strategy Update' }));
    cover.appendChild(el('div', { class: 'r-subtitle', text: state.settings.subtitle || '' }));
    cover.appendChild(el('div', { class: 'r-rule' }));

    const overviewParas = buildOverviewParagraphs(agg);
    if (overviewParas.length || state.settings.contactEmail) {
      const box = el('div', { class: 'r-summary-box' });
      overviewParas.forEach(para => {
        box.appendChild(el('p', { class: para.lead ? 'r-summary-lead' : '', text: para.text }));
      });
      if (state.settings.contactName || state.settings.contactEmail) {
        const p = el('p', { class: 'r-contact' });
        p.appendChild(document.createTextNode('Questions or follow-up? Contact '));
        if (state.settings.contactEmail) {
          const strong = el('strong', { text: state.settings.contactEmail });
          p.appendChild(strong);
        }
        if (state.settings.contactName) {
          p.appendChild(document.createTextNode(state.settings.contactEmail ? ' (' + state.settings.contactName + ')' : state.settings.contactName));
        }
        p.appendChild(document.createTextNode(' directly.'));
        box.appendChild(p);
      }
      cover.appendChild(box);
    }

    cover.appendChild(el('div', { class: 'r-section-title', text: 'Portfolio at a Glance' }));

    // KPI tiles
    const tiles = el('div', { class: 'r-tiles' });
    [
      [agg.total, 'Total initiatives'],
      [agg.active, 'Active & underway'],
      [agg.earlyWins, `Early wins (${EARLY_WIN_THRESHOLD}%+)`],
      [agg.pillarCount, 'Strategic pillars']
    ].forEach(([num, label], i) => {
      tiles.appendChild(el('div', { class: 'r-tile' }, [
        el('div', { class: 'r-tile-num', style: `color:${KPI_COLORS[i]}`, text: String(num) }),
        el('div', { class: 'r-tile-label', text: label })
      ]));
    });
    cover.appendChild(tiles);

    // Bar chart + donut
    const chartsRow = el('div', { class: 'r-charts-row' });

    const barBox = el('div', { class: 'r-chart-box' });
    barBox.appendChild(el('div', { class: 'r-chart-title', text: 'AVERAGE COMPLETION BY PILLAR' }));
    const barChart = el('div', { class: 'r-barchart' });
    const maxAvg = Math.max(25, ...agg.byPillar.map(p => p.avg));
    const axisMax = Math.ceil(maxAvg / 5) * 5;
    agg.byPillar.forEach(p => {
      const row = el('div', { class: 'r-bar-row' });
      row.appendChild(el('div', { class: 'r-bar-label', text: p.pillar, style: `color:${p.color}` }));
      const track = el('div', { class: 'r-bar-track' });
      const pctOfMax = Math.min(100, (p.avg / axisMax) * 100);
      const fill = el('div', { class: 'r-bar-fill' });
      fill.style.width = pctOfMax + '%';
      fill.style.background = p.color;
      const value = el('div', { class: 'r-bar-value', text: fmtPct(p.avg) });
      value.style.left = `calc(${pctOfMax}% + 4pt)`;
      track.appendChild(fill);
      track.appendChild(value);
      row.appendChild(track);
      barChart.appendChild(row);
    });
    barBox.appendChild(barChart);
    const axis = el('div', { class: 'r-bar-axis' });
    axis.appendChild(el('div', { class: 'r-bar-axis-spacer' }));
    const ticks = el('div', { class: 'r-bar-axis-ticks' });
    for (let t = 0; t <= axisMax; t += axisMax / 5) {
      ticks.appendChild(el('span', { text: Math.round(t) + '%' }));
    }
    axis.appendChild(ticks);
    barBox.appendChild(axis);
    chartsRow.appendChild(barBox);

    const donutBox = el('div', { class: 'r-chart-box r-donut-box' });
    donutBox.appendChild(el('div', { class: 'r-chart-title', text: 'PORTFOLIO STATUS' }));
    const donutWrap = el('div', { class: 'r-donut-wrap' });
    const sc = agg.statusCounts;
    const totalForDonut = Math.max(1, agg.total);
    const momentumDeg = (sc.momentum / totalForDonut) * 360;
    const progressDeg = (sc.progress / totalForDonut) * 360;
    const donut = el('div', { class: 'r-donut' });
    donut.style.background = `conic-gradient(${DONUT_COLORS.momentum} 0deg ${momentumDeg}deg, ${DONUT_COLORS.progress} ${momentumDeg}deg ${momentumDeg + progressDeg}deg, ${DONUT_COLORS.none} ${momentumDeg + progressDeg}deg 360deg)`;
    const donutHole = el('div', { class: 'r-donut-hole' }, [
      el('div', { class: 'r-donut-num', text: String(agg.total) }),
      el('div', { class: 'r-donut-label', text: 'initiatives' })
    ]);
    donut.appendChild(donutHole);
    donutWrap.appendChild(donut);
    const legend = el('div', { class: 'r-legend' }, [
      legendItem(DONUT_COLORS.momentum, `Gaining momentum (25%+): ${sc.momentum}`),
      legendItem(DONUT_COLORS.progress, `Early stage (1–24%): ${sc.progress}`),
      legendItem(DONUT_COLORS.none, `Not started: ${sc.none}`)
    ]);
    donutWrap.appendChild(legend);
    donutBox.appendChild(donutWrap);
    chartsRow.appendChild(donutBox);

    cover.appendChild(chartsRow);

    // Pillar overview table
    cover.appendChild(el('div', { class: 'r-section-title', text: 'Pillar Overview' }));
    const table = el('table', { class: 'r-table r-overview-table' });
    const thead = el('thead', {}, [el('tr', {}, [
      el('th', { text: 'Pillar' }), el('th', { text: 'Count' }), el('th', { text: 'Avg %' }), el('th', { text: 'Top performing initiative' })
    ])]);
    table.appendChild(thead);
    const tbody = el('tbody');
    agg.byPillar.forEach(p => {
      const tr = el('tr');
      const nameTd = el('td', { class: 'r-pillar-name', style: `color:${p.color};background:${pillarTint(p.pillar)}`, text: p.pillar });
      tr.appendChild(nameTd);
      tr.appendChild(el('td', { class: 'r-count-cell', text: String(p.count) }));
      tr.appendChild(el('td', { class: 'r-avg-cell', style: `color:${avgTierColor(p.avg)}`, text: fmtPct(p.avg) }));
      tr.appendChild(el('td', { class: 'r-top-cell', text: p.top ? `${p.top.project} — ${fmtPct(p.top.pct)}` : '—' }));
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    cover.appendChild(table);

    root.appendChild(cover);

    // ---- Accomplishments (cross-pillar roundup of reported updates) ----
    const accomplishmentRows = state.rows.filter(r => (r.updates || '').trim());
    if (accomplishmentRows.length) {
      const sec = el('section', { class: 'r-block' });
      sec.appendChild(el('div', { class: 'r-section-title', text: 'Quarterly Accomplishments' }));
      const atable = el('table', { class: 'r-table r-accomplishments-table' });
      const athead = el('thead', {}, [el('tr', {}, [
        el('th', { text: 'Initiative' }), el('th', { text: 'Pillar' }), el('th', { text: 'Accomplishment' })
      ])]);
      atable.appendChild(athead);
      const abody = el('tbody');
      accomplishmentRows.forEach(r => {
        const tr = el('tr');
        tr.appendChild(el('td', { class: 'r-detail-name', text: r.project }));
        tr.appendChild(el('td', { style: `color:${pillarColor(r.pillar)}`, text: r.pillar }));
        tr.appendChild(el('td', { class: 'r-detail-update', text: r.updates }));
        abody.appendChild(tr);
      });
      atable.appendChild(abody);
      sec.appendChild(atable);
      root.appendChild(sec);
    }

    // ---- Risks & Blockers (cross-pillar roundup) ----
    const riskRows = state.rows.filter(r => (r.risks || '').trim());
    if (riskRows.length) {
      const sec = el('section', { class: 'r-block' });
      sec.appendChild(el('div', { class: 'r-section-title', text: 'Quarterly Risks & Blockers' }));
      const rtable = el('table', { class: 'r-table r-risks-table' });
      const rthead = el('thead', {}, [el('tr', { class: 'r-risks-head' }, [
        el('th', { text: 'Initiative' }), el('th', { text: 'Pillar' }), el('th', { text: 'Project Manager' }), el('th', { text: 'Risk / Blocker' })
      ])]);
      rtable.appendChild(rthead);
      const rbody = el('tbody');
      riskRows.forEach(r => {
        const tr = el('tr');
        tr.appendChild(el('td', { class: 'r-detail-name', text: r.project }));
        tr.appendChild(el('td', { style: `color:${pillarColor(r.pillar)}`, text: r.pillar }));
        tr.appendChild(el('td', { class: 'r-detail-pm', text: r.pm || '—' }));
        tr.appendChild(el('td', { class: 'r-detail-update', text: r.risks }));
        rbody.appendChild(tr);
      });
      rtable.appendChild(rbody);
      sec.appendChild(rtable);
      root.appendChild(sec);
    }

    // ---- Coming up / milestones ----
    if (state.milestones.length) {
      const sec = el('section', { class: 'r-block' });
      sec.appendChild(el('div', { class: 'r-section-title', text: state.settings.milestonesTitle || 'Coming Up' }));
      if (state.settings.milestonesIntro) {
        sec.appendChild(el('p', { class: 'r-block-intro', text: state.settings.milestonesIntro }));
      }
      const mtable = el('table', { class: 'r-table r-milestone-table' });
      const mbody = el('tbody');
      state.milestones.forEach(m => {
        if (!m.when && !m.text) return;
        const tr = el('tr');
        tr.appendChild(el('td', { class: 'r-milestone-when', text: m.when || '' }));
        tr.appendChild(el('td', { text: m.text || '' }));
        mbody.appendChild(tr);
      });
      mtable.appendChild(mbody);
      sec.appendChild(mtable);
      root.appendChild(sec);
    }

    // ---- Per-pillar detail tables ----
    agg.pillars.forEach(pillar => {
      const items = state.rows.filter(r => r.pillar === pillar);
      if (!items.length) return;
      const pAgg = agg.byPillar.find(p => p.pillar === pillar);
      const sec = el('section', { class: 'r-block r-pillar-section' });
      const head = el('div', { class: 'r-pillar-head', style: `border-color:${pAgg.color}` });
      head.appendChild(el('span', { class: 'r-pillar-head-name', style: `color:${pAgg.color}`, text: pillar }));
      head.appendChild(el('span', { class: 'r-pillar-head-meta', text: `| ${items.length} initiative${items.length === 1 ? '' : 's'} · ${fmtPct(pAgg.avg)} avg completion` }));
      sec.appendChild(head);

      const dtable = el('table', { class: 'r-table r-detail-table' });
      const dthead = el('thead', {}, [el('tr', { style: `background:${pAgg.color}` }, [
        el('th', { text: 'Initiative' }), el('th', { text: 'Project Manager' }), el('th', { text: '%' }),
        el('th', { text: 'Status' }), el('th', { text: 'Initiative Description' })
      ])]);
      dtable.appendChild(dthead);
      const dbody = el('tbody');
      items.forEach(r => {
        const s = statusFor(r.pct);
        const tr = el('tr');
        tr.appendChild(el('td', { class: 'r-detail-name' + (s.cls === 'status-momentum' ? ' r-detail-name-bold' : ''), text: r.project }));
        tr.appendChild(el('td', { class: 'r-detail-pm', text: r.pm || '—' }));
        tr.appendChild(el('td', { class: 'r-detail-pct', text: fmtPct(r.pct) }));
        tr.appendChild(el('td', {}, [el('span', { class: 'r-status-pill ' + s.cls, text: s.label })]));
        tr.appendChild(el('td', { class: 'r-detail-update', text: r.description || '—' }));
        dbody.appendChild(tr);
      });
      dtable.appendChild(dbody);
      sec.appendChild(dtable);
      root.appendChild(sec);
    });

    if (!state.rows.length) {
      root.appendChild(el('div', { class: 'r-page r-empty', text: 'Add initiatives in the Data Editor, or load sample data, to build a report.' }));
    }
  }

  function legendItem(color, text) {
    return el('div', { class: 'r-legend-item' }, [
      el('span', { class: 'r-legend-swatch', style: `background:${color}` }),
      el('span', { text })
    ]);
  }

  // ---------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------
  function switchTab(view) {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.view === view));
    document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + view));
  }

  // Picks the most common non-empty "quarter" value among newly imported rows,
  // so the report header can update automatically from a fresh import.
  function detectQuarter(rows) {
    const counts = {};
    rows.forEach(r => {
      const q = (r.quarter || '').trim();
      if (q) counts[q] = (counts[q] || 0) + 1;
    });
    const entries = Object.entries(counts);
    if (!entries.length) return null;
    entries.sort((a, b) => b[1] - a[1]);
    return entries[0][0];
  }

  function handleImportedRows(rows, sourceLabel) {
    if (!rows.length) {
      showImportStatus(`No usable rows found in ${sourceLabel}.`, true);
      return;
    }
    state.rows = state.rows.concat(rows);
    const quarter = detectQuarter(rows);
    let quarterNote = '';
    if (quarter && quarter !== state.settings.quarter) {
      state.settings.quarter = quarter;
      quarterNote = ` Report quarter updated to ${quarter}.`;
      renderSettingsForm();
    }
    save();
    renderEditor();
    renderPillarDatalist();
    renderReport();
    showImportStatus(`Imported ${rows.length} initiative${rows.length === 1 ? '' : 's'} from ${sourceLabel}.${quarterNote}`, false);
  }

  function checkXlsxAvailable() {
    if (typeof XLSX !== 'undefined') return true;
    ['btnExportXlsx', 'btnTemplateXlsx'].forEach(id => {
      const btn = document.getElementById(id);
      btn.disabled = true;
      btn.title = 'The XLSX library failed to load (no internet connection?). CSV import/export still works.';
    });
    showImportStatus('The XLSX library could not be loaded (no internet connection?). CSV import/export still works; XLSX buttons are disabled for this session.', true);
    return false;
  }

  function checkDocxAvailable() {
    if (typeof docx !== 'undefined') return true;
    const btn = document.getElementById('btnExportWord');
    btn.disabled = true;
    btn.title = 'The Word export library failed to load (no internet connection?).';
    return false;
  }

  function init() {
    load();
    renderEditor();
    renderPillarDatalist();
    renderMilestones();
    renderSettingsForm();
    wireSettingsForm();
    renderReport();
    checkXlsxAvailable();
    checkDocxAvailable();

    document.querySelectorAll('.tab-btn').forEach(btn => {
      btn.addEventListener('click', () => switchTab(btn.dataset.view));
    });

    document.getElementById('btnAddRow').addEventListener('click', () => {
      state.rows.push(newRow());
      save();
      renderEditor();
      renderReport();
    });

    document.getElementById('btnAddMilestone').addEventListener('click', () => {
      state.milestones.push({ when: '', text: '' });
      save();
      renderMilestones();
      renderReport();
    });

    document.getElementById('btnLoadSample').addEventListener('click', () => {
      if (!window.SAMPLE_DATA) return;
      const rows = window.SAMPLE_DATA.map(d => newRow(Object.assign({ quarter: 'Q3 2026' }, d)));
      state.rows = state.rows.concat(rows);
      const sampleQuarter = detectQuarter(rows);
      if (sampleQuarter) state.settings.quarter = sampleQuarter;
      if (!state.milestones.length) {
        state.milestones = [
          { when: 'End of May', text: 'Copilot Agent goes live on DDC SharePoint — all users gain instant guidance and search.' },
          { when: 'June', text: 'Data Warehouse Standards kickoff meetings begin across disciplines.' },
          { when: 'June', text: 'Autodesk IS Quality Copilot engagement launches via MCP integration.' },
          { when: 'July', text: 'Avail ENG rollout — full Engineering platform content go-live.' },
          { when: 'July', text: 'Enterprise-wide DDD automation tool deployment begins organization-wide.' }
        ];
      }
      if (!state.settings.programName) {
        state.settings.eyebrow = 'PROGRAM STATUS UPDATE';
        state.settings.title = 'Program & Strategy Update';
        state.settings.subtitle = 'Executive Leadership Summary — Sample Data';
        state.settings.programName = 'Design Technology Program';
        state.settings.missionText = 'This update is designed to give our teams a clear, consolidated view of where we stand: the wins worth celebrating, the initiatives that need attention, and the full initiative landscape across every pillar. Replace this sample data by clearing all data and importing your own CSV or XLSX file.';
        state.settings.milestonesTitle = 'Coming Up: June & July 2026';
        state.settings.milestonesIntro = 'The next 6–8 weeks are loaded with high-visibility milestones. Several initiatives in scoping or preparation are set to launch.';
      }
      save();
      renderEditor();
      renderPillarDatalist();
      renderMilestones();
      renderSettingsForm();
      renderReport();
      showImportStatus(`Loaded ${rows.length} sample initiatives.`, false);
    });

    document.getElementById('btnClearAll').addEventListener('click', () => {
      if (!confirm('Clear all initiatives, milestones, and report settings? This cannot be undone.')) return;
      state = { rows: [], milestones: [], settings: { eyebrow: '', quarter: '', title: '', subtitle: '', programName: '', missionText: '', contactName: '', contactEmail: '', milestonesTitle: 'Coming Up', milestonesIntro: '' } };
      save();
      renderEditor();
      renderPillarDatalist();
      renderMilestones();
      renderSettingsForm();
      renderReport();
    });

    document.getElementById('btnExportCsv').addEventListener('click', () => {
      downloadCSV(`initiatives-${timestamp()}.csv`, rowsToCSV(state.rows));
    });

    document.getElementById('btnExportXlsx').addEventListener('click', () => {
      downloadXLSX(`initiatives-${timestamp()}.xlsx`, buildWorkbookFromRows(state.rows));
    });

    document.getElementById('btnTemplateXlsx').addEventListener('click', () => {
      downloadXLSX('initiative-report-template.xlsx', buildTemplateWorkbook());
    });

    document.getElementById('btnTemplateCsv').addEventListener('click', () => {
      const example = newRow({
        quarter: 'Q3 2026',
        pillar: 'Digital Platforms',
        project: 'Example Initiative Name',
        risks: 'Any current risk, blocker, or dependency putting this initiative at risk (leave blank if none).',
        updates: 'Short narrative of what happened this period.',
        pct: 25,
        pm: 'Full Name',
        description: 'One or two sentences describing the goal/scope.'
      });
      downloadCSV('initiative-report-template.csv', rowsToCSV([example]));
    });

    document.getElementById('btnExportPdf').addEventListener('click', () => {
      window.print();
    });

    document.getElementById('btnExportWord').addEventListener('click', () => {
      if (typeof docx === 'undefined') {
        showImportStatus('The Word export library is unavailable (no internet connection?).', true);
        return;
      }
      docx.Packer.toBlob(buildWordDocument()).then(blob => {
        downloadBlob(`report-${timestamp()}.docx`, blob);
      }).catch(err => {
        showImportStatus(`Word export failed: ${err.message}`, true);
      });
    });

    document.getElementById('btnImport').addEventListener('click', () => {
      document.getElementById('fileInput').click();
    });

    document.getElementById('fileInput').addEventListener('change', (e) => {
      const file = e.target.files && e.target.files[0];
      if (!file) return;
      const isXlsx = /\.xlsx?$/i.test(file.name);
      if (isXlsx && typeof XLSX === 'undefined') {
        showImportStatus('The XLSX library is unavailable (no internet connection?). Save the file as CSV and import that instead.', true);
        e.target.value = '';
        return;
      }
      const reader = new FileReader();
      reader.onerror = () => showImportStatus(`Could not read ${file.name}.`, true);
      reader.onload = () => {
        try {
          const rows = isXlsx ? importXLSXArrayBuffer(reader.result) : importCSVText(reader.result);
          handleImportedRows(rows, file.name);
        } catch (err) {
          showImportStatus(`Import failed for ${file.name}: ${err.message}`, true);
        }
        e.target.value = '';
      };
      if (isXlsx) reader.readAsArrayBuffer(file);
      else reader.readAsText(file);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
