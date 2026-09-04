(function () {
  'use strict';

  // ---------------------------------------------------------------------
  // Schema
  // ---------------------------------------------------------------------
  const COLUMNS = ['quarter', 'pillar', 'project', 'risks', 'riskLevel', 'updates', 'pct', 'pm', 'description'];
  const HEADERS = {
    quarter: 'Quarter',
    pillar: 'Strategic Pillar',
    project: 'Project Name',
    risks: 'Recent Risks and Blockers',
    riskLevel: 'Risk Level',
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
    risklevel: 'riskLevel',
    riskseverity: 'riskLevel',
    severity: 'riskLevel',
    level: 'riskLevel',
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
    initiativedetails: 'description',
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
  // Completion tier used for the "On track" KPI tile and the on-track/win
  // bolding rule in the per-pillar detail tables.
  const ON_TRACK_THRESHOLD = 75;

  // Exact hex values extracted from the reference report's status pills.
  const STATUS_INFO = {
    ontrack: { label: 'On track', color: '#0f6e56', bg: '#e9f6f1' },
    inprogress: { label: 'In progress', color: '#185fa5', bg: '#e7f1fa' },
    earlystage: { label: 'Early stage', color: '#ba7517', bg: '#fdf2e3' },
    notstarted: { label: 'Not started', color: '#999999', bg: '#f5f5f5' }
  };
  const RISK_LEVEL_INFO = {
    high: { label: 'High', color: '#a8342a', bg: '#fbe4e1' },
    medium: { label: 'Medium', color: '#854f0b', bg: '#faedd9' },
    low: { label: 'Low', color: '#3b6d11', bg: '#e9f2de' }
  };

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
      riskLevel: (data && data.riskLevel) || '',
      updates: (data && data.updates) || '',
      pct: data && data.pct != null && data.pct !== '' ? clampPct(data.pct) : 0,
      pm: (data && data.pm) || '',
      description: (data && data.description) || ''
    };
  }

  // Normalizes a free-text risk level to one of High/Medium/Low, defaulting
  // to Medium when the initiative has a risk but no level was specified.
  function riskLevelInfo(v) {
    const s = String(v || '').trim().toLowerCase();
    if (s.indexOf('h') === 0) return Object.assign({ key: 'high' }, RISK_LEVEL_INFO.high);
    if (s.indexOf('l') === 0) return Object.assign({ key: 'low' }, RISK_LEVEL_INFO.low);
    return Object.assign({ key: 'medium' }, RISK_LEVEL_INFO.medium);
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
      const winCount = agg.wins.length;
      if (winCount > 0) {
        const opening = quarter ? `${quarter} delivered` : 'This period delivered';
        paras.push({ lead: true, text: `${opening} ${winCount} major win${winCount === 1 ? '' : 's'} across the ${programName}.` });
      } else {
        const opening = quarter ? `${quarter} is` : 'This period is';
        paras.push({ lead: true, text: `${opening} proving to be a period of steady execution for the ${programName}.` });
      }

      let sentence = `Across ${agg.total} tracked initiative${agg.total === 1 ? '' : 's'}, the portfolio is averaging ${fmtPct(agg.avgCompletion)} completion`;
      sentence += agg.onTrack > 0 ? `, with ${agg.onTrack} initiative${agg.onTrack === 1 ? '' : 's'} on track at ${ON_TRACK_THRESHOLD}%+.` : '.';
      paras.push({ lead: false, text: sentence });

      let closing = 'This report details progress by pillar';
      closing += agg.riskCount > 0 ? `, flags ${agg.riskCount} active risk${agg.riskCount === 1 ? '' : 's'} and blockers requiring leadership attention,` : ', flags active risks and blockers requiring leadership attention,';
      closing += ' and outlines where initiatives are tracking toward completion.';
      paras.push({ lead: false, text: closing });
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
    if (pct >= ON_TRACK_THRESHOLD) return Object.assign({ key: 'ontrack', cls: 'status-ontrack' }, STATUS_INFO.ontrack);
    if (pct >= 25) return Object.assign({ key: 'inprogress', cls: 'status-inprogress' }, STATUS_INFO.inprogress);
    if (pct >= 1) return Object.assign({ key: 'earlystage', cls: 'status-earlystage' }, STATUS_INFO.earlystage);
    return Object.assign({ key: 'notstarted', cls: 'status-notstarted' }, STATUS_INFO.notstarted);
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
      throw new Error('Could not find recognizable column headers (expected columns like "Quarter", "Strategic Pillar", "Project Name", "Recent Risks and Blockers", "Risk Level", "Accomplishments/Updates", "Approximate Completion Percentage", "Project Manager", "Initiative Description").');
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
    sheet['!cols'] = [{ wch: 10 }, { wch: 22 }, { wch: 28 }, { wch: 40 }, { wch: 12 }, { wch: 40 }, { wch: 14 }, { wch: 18 }, { wch: 40 }];
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
      riskLevel: 'Medium',
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
      ['7. "Risk Level" is optional (High / Medium / Low) — shown as a colored badge next to each flagged' +
        ' risk. Left blank, a flagged risk defaults to Medium.'],
      ['8. "Accomplishments/Updates" is optional — any row with text here appears as a "win" card on the' +
        ' report cover and gets a green "Win:" callout in that initiative’s detail table.'],
      ['9. Save as .xlsx or .csv and import it back into the Report Builder using "Import CSV / XLSX".'],
      ['10. Completion status shown per initiative (Not started / Early stage / In progress / On track) is' +
        ' calculated automatically: 0% = Not started, 1-24% = Early stage, 25-74% = In progress, 75%+ = On track.']
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
    function sideBorder() {
      return {
        top: { style: BorderStyle.SINGLE, size: 4, color: 'E0E4EA' },
        bottom: { style: BorderStyle.SINGLE, size: 4, color: 'E0E4EA' },
        left: { style: BorderStyle.SINGLE, size: 4, color: 'E0E4EA' },
        right: { style: BorderStyle.SINGLE, size: 4, color: 'E0E4EA' }
      };
    }

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
        shading: opts.fill ? { fill: hex6(opts.fill), type: ShadingType.CLEAR, color: 'auto' } : undefined,
        border: opts.border,
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
        borders: opts.border || (opts.noBorder ? NO_BORDERS : undefined),
        margins: opts.margins || { top: 60, bottom: 60, left: 100, right: 100 },
        verticalAlign: opts.valign || VerticalAlign.CENTER
      });
    }
    function fullTable(rows, opts) {
      return new Table({
        width: { size: 100, type: WidthType.PERCENTAGE },
        rows,
        borders: (opts && opts.noBorder) ? NO_BORDERS : undefined
      });
    }
    // "Risk:" / "Win:" inline callout, stacked as extra paragraphs inside the
    // Initiative Details cell — matches the reference report's colored,
    // left-bordered note boxes under each initiative's description.
    function calloutParagraph(label, text, color, bg, isLast) {
      return new Paragraph({
        shading: { fill: bg, type: ShadingType.CLEAR, color: 'auto' },
        border: { left: { style: BorderStyle.SINGLE, size: 16, color } },
        children: [run(label + ': ', { bold: true, color, size: 14 }), run(text, { color, size: 14 })],
        spacing: { before: 40, after: isLast ? 0 : 40 }
      });
    }
    function detailCellParagraphs(r) {
      const hasRisk = (r.risks || '').trim();
      const hasWin = (r.updates || '').trim();
      const paras = [p(r.description || '—', { color: '444444', size: 15, after: (hasRisk || hasWin) ? 40 : 0 })];
      if (hasRisk) paras.push(calloutParagraph('Risk', r.risks, '7A4500', 'FFF7F0', !hasWin));
      if (hasWin) paras.push(calloutParagraph('Win', r.updates, '0A4A38', 'F0FAF4', true));
      return paras;
    }
    // A single bordered "win" card: checkmark + initiative name, pillar, body.
    function winCard(r) {
      return new Table({
        width: { size: 100, type: WidthType.PERCENTAGE },
        borders: sideBorder(),
        rows: [new TableRow({ children: [
          cell([
            new Paragraph({ children: [run('✓  ', { bold: true, color: '0F6E56', size: 18 }), run(r.project, { bold: true, color: '1A1A1A', size: 15 })], spacing: { after: 40 } }),
            p(r.pillar, { bold: true, color: pillarColor(r.pillar), size: 14, after: 40 }),
            p(r.updates, { color: '555555', size: 14, after: 0 })
          ], { margins: { top: 120, bottom: 120, left: 140, right: 140 }, valign: VerticalAlign.TOP })
        ] })]
      });
    }

    const agg = computeAggregates();
    const quarter = (state.settings.quarter || '').trim();
    const children = [];

    // ---- Header ----
    children.push(p(eyebrowText(), { size: 14, color: '888888', bold: true, after: 40 }));
    children.push(new Paragraph({
      children: [run(state.settings.title || 'Program & Strategy Update', { bold: true, size: 30, color: '1F3864', font: 'Georgia' })],
      spacing: { after: 40 }
    }));
    const metaRuns = [run(state.settings.subtitle || 'Executive Leadership Summary', { color: '666666', size: 17 })];
    if (quarter) metaRuns.push(run(' — ' + quarter, { color: '666666', size: 17 }));
    metaRuns.push(run('   ·   Overall portfolio avg: ', { color: '666666', size: 17 }));
    metaRuns.push(run(fmtPct(agg.avgCompletion), { color: '666666', size: 17, bold: true }));
    metaRuns.push(run('   ·   ' + agg.total + ' initiative' + (agg.total === 1 ? '' : 's') + ' across ' + agg.pillarCount + ' pillar' + (agg.pillarCount === 1 ? '' : 's'), { color: '666666', size: 17 }));
    children.push(new Paragraph({ children: metaRuns, spacing: { after: 100 } }));
    children.push(new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 24, color: '185FA5' } }, spacing: { after: 160 } }));

    // ---- Summary box ----
    const overviewParas = buildOverviewParagraphs(agg);
    if (overviewParas.length || state.settings.contactEmail) {
      overviewParas.forEach((para, i) => {
        children.push(new Paragraph({
          shading: { fill: 'F0F5FA', type: ShadingType.CLEAR, color: 'auto' },
          border: i === 0 ? { left: { style: BorderStyle.SINGLE, size: 24, color: '185FA5' } } : undefined,
          children: [run(para.text, { bold: para.lead, color: para.lead ? '1F3864' : '333333', size: 16 })],
          spacing: { before: i === 0 ? 100 : 0, after: 60 }
        }));
      });
      if (state.settings.contactName || state.settings.contactEmail) {
        const parts = [run('Questions? Contact ', { color: '555555', size: 14 })];
        if (state.settings.contactEmail) parts.push(run(state.settings.contactEmail, { bold: true, color: '185FA5', size: 14 }));
        if (state.settings.contactName) parts.push(run(state.settings.contactEmail ? ' (' + state.settings.contactName + ')' : state.settings.contactName, { color: '888888', size: 14 }));
        parts.push(run(' directly.', { color: '555555', size: 14 }));
        children.push(new Paragraph({ shading: { fill: 'F0F5FA', type: ShadingType.CLEAR, color: 'auto' }, children: parts, spacing: { after: 200 } }));
      }
    }

    children.push(p('Portfolio at a Glance', { bold: true, color: '1F3864', size: 18, after: 120 }));

    // KPI tiles
    const kpiVals = [
      [agg.total, 'Total initiatives', '1F3864'],
      [agg.active, 'Active & underway', '185FA5'],
      [agg.onTrack, 'On track (' + ON_TRACK_THRESHOLD + '%+)', '0F6E56'],
      [agg.riskCount, 'Risks / blockers', '993C1D']
    ];
    children.push(fullTable([new TableRow({
      children: kpiVals.map(([num, label, color]) => cell([
        p(String(num), { bold: true, size: 38, color, align: AlignmentType.CENTER, after: 20 }),
        p(label, { size: 14, color: '777777', align: AlignmentType.CENTER, after: 0 })
      ], { width: 25, fill: 'F4F5FA' }))
    })]));

    children.push(p('', { after: 160 }));

    // Average completion by pillar (as a table with shaded "bar" cells, fixed 0-100% axis)
    children.push(p('AVERAGE COMPLETION BY PILLAR', { bold: true, size: 14, color: '888888', after: 100 }));
    const axisMax = 100;
    const barRows = agg.byPillar.map(x => {
      const pct = Math.max(2, Math.min(100, Math.round((x.avg / axisMax) * 100)));
      const barInner = new Table({
        width: { size: 100, type: WidthType.PERCENTAGE },
        borders: NO_BORDERS,
        rows: [new TableRow({
          children: [
            cell(p(''), { width: pct, fill: x.color, noBorder: true }),
            cell(p(''), { width: Math.max(1, 100 - pct), fill: 'F0F1F5', noBorder: true })
          ]
        })]
      });
      return new TableRow({ children: [
        cell(p(x.pillar, { bold: true, color: x.color, size: 15 }), { width: 25, noBorder: true }),
        cell(barInner, { width: 60, noBorder: true }),
        cell(p(fmtPct(x.avg), { bold: true, size: 15, align: AlignmentType.RIGHT }), { width: 15, noBorder: true })
      ] });
    });
    const axisRow = new TableRow({ children: [cell(p(''), { width: 25, noBorder: true })].concat(
      ['0%', '25%', '50%', '75%', '100%'].map(t => cell(p(t, { color: 'AAAAAA', size: 14 }), { width: 15, noBorder: true }))
    ) });
    children.push(fullTable(barRows.concat([axisRow]), { noBorder: true }));

    children.push(p('', { after: 160 }));

    // Portfolio status (4-tier)
    children.push(p('PORTFOLIO STATUS (' + agg.total + ' INITIATIVE' + (agg.total === 1 ? '' : 'S') + ')', { bold: true, size: 14, color: '888888', after: 100 }));
    const sc = agg.statusCounts;
    const statusRows = [
      [STATUS_INFO.ontrack.label + ' (' + ON_TRACK_THRESHOLD + '%+)', sc.ontrack, STATUS_INFO.ontrack.color],
      [STATUS_INFO.inprogress.label, sc.inprogress, STATUS_INFO.inprogress.color],
      [STATUS_INFO.earlystage.label, sc.earlystage, STATUS_INFO.earlystage.color],
      [STATUS_INFO.notstarted.label, sc.notstarted, STATUS_INFO.notstarted.color]
    ].map(([label, count, color]) => new TableRow({ children: [
      cell(p(''), { width: 6, fill: hex6(color), noBorder: true }),
      cell(p(label + ': ' + count, { size: 14 }), { width: 94, noBorder: true })
    ] }));
    children.push(fullTable(statusRows, { noBorder: true }));

    // Accomplishments & Wins (cards, 2 per row)
    if (agg.wins.length) {
      const winsTitle = quarter ? quarter + ' Accomplishments & Wins' : 'Accomplishments & Wins';
      children.push(p(winsTitle, { bold: true, color: '0F6E56', size: 17, before: 300, after: 120 }));
      const cards = agg.wins.map(winCard);
      const winRows = [];
      for (let i = 0; i < cards.length; i += 2) {
        const rowCells = [cell(cards[i], { width: 49, noBorder: true, margins: { top: 0, bottom: 120, left: 0, right: 60 } })];
        rowCells.push(cards[i + 1]
          ? cell(cards[i + 1], { width: 49, noBorder: true, margins: { top: 0, bottom: 120, left: 60, right: 0 } })
          : cell(p(''), { width: 49, noBorder: true }));
        winRows.push(new TableRow({ children: rowCells }));
      }
      children.push(fullTable(winRows, { noBorder: true }));
    }

    // Risks & Blockers (with severity level)
    if (agg.riskRows.length) {
      const risksTitle = quarter ? quarter + ' Risks & Blockers' : 'Risks & Blockers';
      children.push(p(risksTitle, { bold: true, color: '993C1D', size: 17, before: 300, after: 120 }));
      const rHeader = new TableRow({ children: [
        cell(p('Initiative', { bold: true, color: 'FFFFFF', size: 14 }), { width: 24, fill: '993C1D' }),
        cell(p('Pillar', { bold: true, color: 'FFFFFF', size: 14 }), { width: 16, fill: '993C1D' }),
        cell(p('Level', { bold: true, color: 'FFFFFF', size: 14 }), { width: 12, fill: '993C1D' }),
        cell(p('Details', { bold: true, color: 'FFFFFF', size: 14 }), { width: 48, fill: '993C1D' })
      ] });
      const rRows = agg.riskRows.map(r => {
        const lvl = riskLevelInfo(r.riskLevel);
        return new TableRow({ children: [
          cell(p(r.project, { bold: true, size: 14 })),
          cell(p(r.pillar, { color: pillarColor(r.pillar), size: 14 })),
          cell(p(lvl.label, { bold: true, color: hex6(lvl.color), size: 14, align: AlignmentType.CENTER }), { fill: lvl.bg }),
          cell(p(r.risks, { color: '444444', size: 14 }))
        ] });
      });
      children.push(fullTable([rHeader].concat(rRows)));
    }

    // Coming up / milestones (optional; not part of the reference layout, kept for continuity)
    const milestoneRows = state.milestones.filter(m => m.when || m.text);
    if (milestoneRows.length) {
      children.push(p(state.settings.milestonesTitle || 'Coming Up', { bold: true, color: '1F3864', size: 17, before: 300, after: 80 }));
      if (state.settings.milestonesIntro) children.push(p(state.settings.milestonesIntro, { color: '555555', size: 14, after: 120 }));
      const mRows = milestoneRows.map(m => new TableRow({ children: [
        cell(p(m.when || '', { bold: true, color: '185FA5', size: 14 }), { width: 20 }),
        cell(p(m.text || '', { size: 14 }), { width: 80 })
      ] }));
      children.push(fullTable(mRows));
    }

    // Per-pillar detail tables (each pillar starts on a fresh page)
    agg.pillars.forEach(pillar => {
      const items = state.rows.filter(r => r.pillar === pillar);
      if (!items.length) return;
      const pAgg = agg.byPillar.find(x => x.pillar === pillar);
      children.push(new Paragraph({
        children: [
          run(pillar, { bold: true, color: pAgg.color, size: 19 }),
          run('   |   ' + items.length + ' initiative' + (items.length === 1 ? '' : 's') + ' · ' + fmtPct(pAgg.avg) + ' avg completion', { color: '888888', size: 14 })
        ],
        spacing: { before: 0, after: 120 },
        pageBreakBefore: true
      }));
      const dHeader = new TableRow({ children: [
        cell(p('Initiative', { bold: true, color: 'FFFFFF', size: 15 }), { width: 26, fill: pAgg.color }),
        cell(p('Project Manager', { bold: true, color: 'FFFFFF', size: 15 }), { width: 13, fill: pAgg.color }),
        cell(p('%', { bold: true, color: 'FFFFFF', size: 15 }), { width: 7, fill: pAgg.color }),
        cell(p('Status', { bold: true, color: 'FFFFFF', size: 15 }), { width: 18, fill: pAgg.color }),
        cell(p('Initiative Details', { bold: true, color: 'FFFFFF', size: 15 }), { width: 36, fill: pAgg.color })
      ] });
      const dRows = items.map(r => {
        const s = statusFor(r.pct);
        const hasWin = !!(r.updates || '').trim();
        const boldName = s.key === 'ontrack' || hasWin;
        return new TableRow({ children: [
          cell(p(r.project, { bold: boldName, size: 15 })),
          cell(p(r.pm || '—', { color: '555555', size: 15 })),
          cell(p(fmtPct(r.pct), { bold: true, size: 15 })),
          cell(p(s.label, { bold: true, color: hex6(s.color), size: 14 }), { fill: s.bg }),
          cell(detailCellParagraphs(r), { width: 36 })
        ] });
      });
      children.push(fullTable([dHeader].concat(dRows)));
    });

    return new Document({
      sections: [{
        properties: {
          page: {
            size: { width: convertInchesToTwip(8.5), height: convertInchesToTwip(11) },
            margin: { top: 750, bottom: 750, left: 750, right: 750 }
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
      const tr = el('tr', {}, [el('td', { colspan: '10', class: 'empty-row', text: 'No initiatives yet. Add one, import a file, or load sample data.' })]);
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
      const riskLevelInput = el('select', { 'data-field': 'riskLevel' }, [
        el('option', { value: '' }, [document.createTextNode('— Medium —')]),
        el('option', { value: 'High' }, [document.createTextNode('High')]),
        el('option', { value: 'Medium' }, [document.createTextNode('Medium')]),
        el('option', { value: 'Low' }, [document.createTextNode('Low')])
      ]);
      riskLevelInput.value = row.riskLevel;
      const updatesInput = el('textarea', { rows: '2', 'data-field': 'updates' });
      updatesInput.value = row.updates;
      const pctInput = el('input', { type: 'number', min: '0', max: '100', step: '1', value: String(row.pct), 'data-field': 'pct' });
      const pmInput = el('input', { type: 'text', value: row.pm, 'data-field': 'pm' });
      const descInput = el('textarea', { rows: '2', 'data-field': 'description' });
      descInput.value = row.description;

      [quarterInput, pillarInput, projectInput, risksInput, riskLevelInput, updatesInput, pctInput, pmInput, descInput].forEach(inp => {
        const evt = inp.tagName === 'SELECT' ? 'change' : 'input';
        inp.addEventListener(evt, () => {
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
      tr.appendChild(el('td', {}, [riskLevelInput]));
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
    const onTrack = rows.filter(r => r.pct >= ON_TRACK_THRESHOLD).length;
    const wins = rows.filter(r => (r.updates || '').trim());
    const riskRows = rows.filter(r => (r.risks || '').trim());
    const avgCompletion = total ? Math.round((rows.reduce((s, r) => s + r.pct, 0) / total) * 10) / 10 : 0;
    const pillars = orderedPillars();

    const byPillar = pillars.map(p => {
      const items = rows.filter(r => r.pillar === p);
      const avg = items.length ? items.reduce((s, r) => s + r.pct, 0) / items.length : 0;
      const top = items.slice().sort((a, b) => b.pct - a.pct)[0];
      return { pillar: p, count: items.length, avg: Math.round(avg * 10) / 10, top, color: pillarColor(p) };
    });

    const statusCounts = { ontrack: 0, inprogress: 0, earlystage: 0, notstarted: 0 };
    rows.forEach(r => { statusCounts[statusFor(r.pct).key]++; });

    return {
      total, active, onTrack, wins, riskRows, riskCount: riskRows.length, avgCompletion,
      pillarCount: pillars.length, byPillar, statusCounts, pillars
    };
  }

  // ---------------------------------------------------------------------
  // Report rendering
  // ---------------------------------------------------------------------
  function fmtPct(n) { return `${n}%`; }

  function renderReport() {
    const root = document.getElementById('reportRoot');
    root.innerHTML = '';
    const agg = computeAggregates();

    // ---- Header / summary section (always starts its own printed page) ----
    const cover = el('section', { class: 'r-page r-cover' });
    cover.appendChild(el('div', { class: 'r-eyebrow', text: eyebrowText() }));
    cover.appendChild(el('h1', { class: 'r-title', text: state.settings.title || 'Program & Strategy Update' }));
    const quarter = (state.settings.quarter || '').trim();
    const metaBits = [state.settings.subtitle || 'Executive Leadership Summary'];
    if (quarter) metaBits[0] += ` — ${quarter}`;
    const metaLine = el('div', { class: 'r-subtitle' });
    metaLine.appendChild(document.createTextNode(metaBits[0] + '   ·   Overall portfolio avg: '));
    metaLine.appendChild(el('strong', { text: fmtPct(agg.avgCompletion) }));
    metaLine.appendChild(document.createTextNode(`   ·   ${agg.total} initiative${agg.total === 1 ? '' : 's'} across ${agg.pillarCount} pillar${agg.pillarCount === 1 ? '' : 's'}`));
    cover.appendChild(metaLine);
    cover.appendChild(el('div', { class: 'r-rule' }));

    const overviewParas = buildOverviewParagraphs(agg);
    if (overviewParas.length || state.settings.contactEmail) {
      const box = el('div', { class: 'r-summary-box' });
      overviewParas.forEach(para => {
        box.appendChild(el('p', { class: para.lead ? 'r-summary-lead' : '', text: para.text }));
      });
      if (state.settings.contactName || state.settings.contactEmail) {
        const p = el('p', { class: 'r-contact' });
        p.appendChild(document.createTextNode('Questions? Contact '));
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
      [agg.total, 'Total initiatives', '#1f3864'],
      [agg.active, 'Active & underway', '#185fa5'],
      [agg.onTrack, `On track (${ON_TRACK_THRESHOLD}%+)`, '#0f6e56'],
      [agg.riskCount, 'Risks / blockers', '#993c1d']
    ].forEach(([num, label, color]) => {
      tiles.appendChild(el('div', { class: 'r-tile' }, [
        el('div', { class: 'r-tile-num', style: `color:${color}`, text: String(num) }),
        el('div', { class: 'r-tile-label', text: label })
      ]));
    });
    cover.appendChild(tiles);

    // Bar chart + status legend
    const chartsRow = el('div', { class: 'r-charts-row' });

    const barBox = el('div', { class: 'r-chart-box' });
    barBox.appendChild(el('div', { class: 'r-chart-title', text: 'AVERAGE COMPLETION BY PILLAR' }));
    const barChart = el('div', { class: 'r-barchart' });
    const axisMax = 100;
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
    for (let t = 0; t <= axisMax; t += axisMax / 4) {
      ticks.appendChild(el('span', { text: Math.round(t) + '%' }));
    }
    axis.appendChild(ticks);
    barBox.appendChild(axis);
    chartsRow.appendChild(barBox);

    const statusBox = el('div', { class: 'r-chart-box r-status-box' });
    statusBox.appendChild(el('div', { class: 'r-chart-title', text: `PORTFOLIO STATUS (${agg.total} INITIATIVE${agg.total === 1 ? '' : 'S'})` }));
    const sc = agg.statusCounts;
    const legend = el('div', { class: 'r-legend r-legend-standalone' }, [
      legendItem(STATUS_INFO.ontrack.color, `${STATUS_INFO.ontrack.label} (${ON_TRACK_THRESHOLD}%+): ${sc.ontrack}`),
      legendItem(STATUS_INFO.inprogress.color, `${STATUS_INFO.inprogress.label}: ${sc.inprogress}`),
      legendItem(STATUS_INFO.earlystage.color, `${STATUS_INFO.earlystage.label}: ${sc.earlystage}`),
      legendItem(STATUS_INFO.notstarted.color, `${STATUS_INFO.notstarted.label}: ${sc.notstarted}`)
    ]);
    statusBox.appendChild(legend);
    chartsRow.appendChild(statusBox);

    cover.appendChild(chartsRow);
    root.appendChild(cover);

    // ---- Accomplishments & Wins (cross-pillar roundup of reported updates) ----
    if (agg.wins.length) {
      const sec = el('section', { class: 'r-block' });
      const winsTitle = quarter ? `${quarter} Accomplishments & Wins` : 'Accomplishments & Wins';
      sec.appendChild(el('div', { class: 'r-section-title r-section-title-win', text: winsTitle }));
      const grid = el('div', { class: 'r-win-grid' });
      agg.wins.forEach(r => {
        const card = el('div', { class: 'r-win-card' });
        card.appendChild(el('div', { class: 'r-win-card-title' }, [
          el('span', { class: 'r-win-check', text: '✓' }),
          el('span', { text: r.project })
        ]));
        card.appendChild(el('div', { class: 'r-win-card-pillar', style: `color:${pillarColor(r.pillar)}`, text: r.pillar }));
        card.appendChild(el('div', { class: 'r-win-card-body', text: r.updates }));
        grid.appendChild(card);
      });
      sec.appendChild(grid);
      root.appendChild(sec);
    }

    // ---- Risks & Blockers (cross-pillar roundup, with severity level) ----
    if (agg.riskRows.length) {
      const sec = el('section', { class: 'r-block' });
      const risksTitle = quarter ? `${quarter} Risks & Blockers` : 'Risks & Blockers';
      sec.appendChild(el('div', { class: 'r-section-title r-section-title-risk', text: risksTitle }));
      const rtable = el('table', { class: 'r-table r-risks-table' });
      const rthead = el('thead', {}, [el('tr', {}, [
        el('th', { text: 'Initiative' }), el('th', { text: 'Pillar' }), el('th', { text: 'Level' }), el('th', { text: 'Details' })
      ])]);
      rtable.appendChild(rthead);
      const rbody = el('tbody');
      agg.riskRows.forEach(r => {
        const lvl = riskLevelInfo(r.riskLevel);
        const tr = el('tr');
        tr.appendChild(el('td', { class: 'r-detail-name', text: r.project }));
        tr.appendChild(el('td', { style: `color:${pillarColor(r.pillar)}`, text: r.pillar }));
        tr.appendChild(el('td', {}, [el('span', { class: 'r-risk-level-badge', style: `color:${lvl.color};background:${lvl.bg}`, text: lvl.label })]));
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
        el('th', { text: 'Status' }), el('th', { text: 'Initiative Details' })
      ])]);
      dtable.appendChild(dthead);
      const dbody = el('tbody');
      items.forEach(r => {
        const s = statusFor(r.pct);
        const hasRisk = (r.risks || '').trim();
        const hasWin = (r.updates || '').trim();
        const tr = el('tr');
        tr.appendChild(el('td', { class: 'r-detail-name' + ((s.key === 'ontrack' || hasWin) ? ' r-detail-name-bold' : ''), text: r.project }));
        tr.appendChild(el('td', { class: 'r-detail-pm', text: r.pm || '—' }));
        tr.appendChild(el('td', { class: 'r-detail-pct', text: fmtPct(r.pct) }));
        tr.appendChild(el('td', {}, [el('span', { class: 'r-status-pill', style: `color:${s.color};background:${s.bg}`, text: s.label })]));
        const detailsTd = el('td', { class: 'r-detail-update' });
        detailsTd.appendChild(el('div', { text: r.description || '—' }));
        if (hasRisk) detailsTd.appendChild(el('div', { class: 'r-callout r-callout-risk' }, [el('strong', { text: 'Risk: ' }), document.createTextNode(r.risks)]));
        if (hasWin) detailsTd.appendChild(el('div', { class: 'r-callout r-callout-win' }, [el('strong', { text: 'Win: ' }), document.createTextNode(r.updates)]));
        tr.appendChild(detailsTd);
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
        riskLevel: 'Medium',
        updates: 'Short narrative of what happened this period.',
        pct: 25,
        pm: 'Full Name',
        description: 'One or two sentences describing the goal/scope.'
      });
      downloadCSV('initiative-report-template.csv', rowsToCSV([example]));
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
