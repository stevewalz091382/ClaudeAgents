(function () {
  'use strict';

  // ---------------------------------------------------------------------
  // Schema
  // ---------------------------------------------------------------------
  const COLUMNS = ['pillar', 'project', 'updates', 'pct', 'pm', 'description'];
  const HEADERS = {
    pillar: 'Strategic Pillar',
    project: 'Project Name',
    updates: 'Accomplishments/Updates',
    pct: 'Approximate Completion Percentage',
    pm: 'Project Manager',
    description: 'Initiative Description'
  };
  // Accepted alternate header spellings on import, normalized (lowercase, alnum only) -> internal key
  const HEADER_ALIASES = {
    strategicpillar: 'pillar',
    pillar: 'pillar',
    projectname: 'project',
    project: 'project',
    initiative: 'project',
    initiativename: 'project',
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
  const PILLAR_COLORS = {
    'Digital Platforms': '#1d4ed8',
    'Data': '#15803d',
    'Technology Innovation': '#6d28d9',
    'Quality': '#9a3324',
    'Execution & Delivery': '#c2760c',
    'Implementation': '#52525b'
  };
  const FALLBACK_PALETTE = ['#0891b2', '#be185d', '#4d7c0f', '#a16207', '#334155', '#7c2d12', '#0f766e', '#b91c1c'];

  const STORAGE_KEY = 'reportBuilder.v1';

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  let nextId = 1;
  let state = {
    rows: [],
    milestones: [],
    settings: {
      eyebrow: 'PROGRAM STATUS UPDATE',
      title: 'Program & Strategy Update',
      subtitle: 'Executive Leadership Summary',
      summary: '',
      contactName: '',
      contactEmail: ''
    }
  };

  function newRow(data) {
    return {
      id: 'r' + (nextId++),
      pillar: (data && data.pillar) || '',
      project: (data && data.project) || '',
      updates: (data && data.updates) || '',
      pct: data && data.pct != null && data.pct !== '' ? clampPct(data.pct) : 0,
      pm: (data && data.pm) || '',
      description: (data && data.description) || ''
    };
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
      throw new Error('Could not find recognizable column headers (expected columns like "Strategic Pillar", "Project Name", "Accomplishments/Updates", "Approximate Completion Percentage", "Project Manager", "Initiative Description").');
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
    sheet['!cols'] = [{ wch: 22 }, { wch: 28 }, { wch: 50 }, { wch: 14 }, { wch: 18 }, { wch: 40 }];
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, sheet, 'Initiatives');
    return wb;
  }

  function buildTemplateWorkbook() {
    const example = newRow({
      pillar: 'Digital Platforms',
      project: 'Example Initiative Name',
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
      ['3. "Approximate Completion Percentage" is a number from 0-100 (do not include the % sign).'],
      ['4. "Strategic Pillar" groups initiatives in the report. Use a consistent name per pillar' +
        ' (e.g. Digital Platforms, Data, Technology Innovation, Quality, Execution & Delivery, Implementation)' +
        ' — or your own pillar names.'],
      ['5. Save as .xlsx or .csv and import it back into the Report Builder using "Import CSV / XLSX".'],
      ['6. Completion status shown in the report (Not started / In progress / Gaining momentum) is calculated' +
        ' automatically: 0% = Not started, 1-24% = In progress, 25%+ = Gaining momentum.']
    ]);
    instructions['!cols'] = [{ wch: 100 }];
    XLSX.utils.book_append_sheet(wb, instructions, 'Instructions');
    return wb;
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
      const tr = el('tr', {}, [el('td', { colspan: '7', class: 'empty-row', text: 'No initiatives yet. Add one, import a file, or load sample data.' })]);
      body.appendChild(tr);
      return;
    }
    state.rows.forEach(row => {
      const tr = el('tr', { 'data-id': row.id });

      const pillarInput = el('input', { type: 'text', value: row.pillar, list: 'pillarSuggestions', 'data-field': 'pillar' });
      const projectInput = el('input', { type: 'text', value: row.project, 'data-field': 'project' });
      const updatesInput = el('textarea', { rows: '2', 'data-field': 'updates' });
      updatesInput.value = row.updates;
      const pctInput = el('input', { type: 'number', min: '0', max: '100', step: '1', value: String(row.pct), 'data-field': 'pct' });
      const pmInput = el('input', { type: 'text', value: row.pm, 'data-field': 'pm' });
      const descInput = el('textarea', { rows: '2', 'data-field': 'description' });
      descInput.value = row.description;

      [pillarInput, projectInput, updatesInput, pctInput, pmInput, descInput].forEach(inp => {
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

      tr.appendChild(el('td', {}, [pillarInput]));
      tr.appendChild(el('td', {}, [projectInput]));
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
    document.getElementById('setTitle').value = state.settings.title || '';
    document.getElementById('setSubtitle').value = state.settings.subtitle || '';
    document.getElementById('setSummary').value = state.settings.summary || '';
    document.getElementById('setContactName').value = state.settings.contactName || '';
    document.getElementById('setContactEmail').value = state.settings.contactEmail || '';
  }

  function wireSettingsForm() {
    const map = {
      setEyebrow: 'eyebrow', setTitle: 'title', setSubtitle: 'subtitle',
      setSummary: 'summary', setContactName: 'contactName', setContactEmail: 'contactEmail'
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
    const earlyWins = rows.filter(r => r.pct >= 25).length;
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

  function renderReport() {
    const root = document.getElementById('reportRoot');
    root.innerHTML = '';
    const agg = computeAggregates();

    // ---- Cover / summary section ----
    const cover = el('section', { class: 'r-page r-cover' });
    cover.appendChild(el('div', { class: 'r-eyebrow', text: state.settings.eyebrow || '' }));
    cover.appendChild(el('h1', { class: 'r-title', text: state.settings.title || 'Program & Strategy Update' }));
    cover.appendChild(el('div', { class: 'r-subtitle', text: state.settings.subtitle || '' }));
    cover.appendChild(el('div', { class: 'r-rule' }));

    if (state.settings.summary || state.settings.contactEmail) {
      const box = el('div', { class: 'r-summary-box' });
      (state.settings.summary || '').split('\n').filter(Boolean).forEach(line => {
        box.appendChild(el('p', { text: line }));
      });
      if (state.settings.contactName || state.settings.contactEmail) {
        const p = el('p', { class: 'r-contact' });
        p.appendChild(document.createTextNode('Questions or follow-up? Contact '));
        const strong = el('strong', { text: state.settings.contactName || state.settings.contactEmail || '' });
        p.appendChild(strong);
        if (state.settings.contactEmail) {
          p.appendChild(document.createTextNode(' — ' + state.settings.contactEmail));
        }
        box.appendChild(p);
      }
      cover.appendChild(box);
    }

    // KPI tiles
    const tiles = el('div', { class: 'r-tiles' });
    [
      [agg.total, 'Total initiatives'],
      [agg.active, 'Active & underway'],
      [agg.earlyWins, 'Early wins (25%+)'],
      [agg.pillarCount, 'Strategic pillars']
    ].forEach(([num, label]) => {
      tiles.appendChild(el('div', { class: 'r-tile' }, [
        el('div', { class: 'r-tile-num', text: String(num) }),
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
    agg.byPillar.forEach(p => {
      const row = el('div', { class: 'r-bar-row' });
      row.appendChild(el('div', { class: 'r-bar-label', text: p.pillar, style: `color:${p.color}` }));
      const track = el('div', { class: 'r-bar-track' });
      const fill = el('div', { class: 'r-bar-fill' });
      fill.style.width = Math.min(100, (p.avg / maxAvg) * 100) + '%';
      fill.style.background = p.color;
      track.appendChild(fill);
      row.appendChild(track);
      row.appendChild(el('div', { class: 'r-bar-value', text: fmtPct(p.avg) }));
      barChart.appendChild(row);
    });
    barBox.appendChild(barChart);
    chartsRow.appendChild(barBox);

    const donutBox = el('div', { class: 'r-chart-box r-donut-box' });
    donutBox.appendChild(el('div', { class: 'r-chart-title', text: 'PORTFOLIO STATUS' }));
    const donutWrap = el('div', { class: 'r-donut-wrap' });
    const sc = agg.statusCounts;
    const totalForDonut = Math.max(1, agg.total);
    const momentumDeg = (sc.momentum / totalForDonut) * 360;
    const progressDeg = (sc.progress / totalForDonut) * 360;
    const donut = el('div', { class: 'r-donut' });
    donut.style.background = `conic-gradient(#16a34a 0deg ${momentumDeg}deg, #2563eb ${momentumDeg}deg ${momentumDeg + progressDeg}deg, #d1d5db ${momentumDeg + progressDeg}deg 360deg)`;
    const donutHole = el('div', { class: 'r-donut-hole' }, [
      el('div', { class: 'r-donut-num', text: String(agg.total) }),
      el('div', { class: 'r-donut-label', text: 'initiatives' })
    ]);
    donut.appendChild(donutHole);
    donutWrap.appendChild(donut);
    const legend = el('div', { class: 'r-legend' }, [
      legendItem('#16a34a', `Gaining momentum (25%+): ${sc.momentum}`),
      legendItem('#2563eb', `Early stage (1–24%): ${sc.progress}`),
      legendItem('#d1d5db', `Not started: ${sc.none}`)
    ]);
    donutWrap.appendChild(legend);
    donutBox.appendChild(donutWrap);
    chartsRow.appendChild(donutBox);

    cover.appendChild(chartsRow);

    // Pillar overview table
    cover.appendChild(el('div', { class: 'r-section-title', text: 'Pillar Overview' }));
    const table = el('table', { class: 'r-table' });
    const thead = el('thead', {}, [el('tr', {}, [
      el('th', { text: 'Pillar' }), el('th', { text: 'Count' }), el('th', { text: 'Avg %' }), el('th', { text: 'Top performing initiative' })
    ])]);
    table.appendChild(thead);
    const tbody = el('tbody');
    agg.byPillar.forEach(p => {
      const tr = el('tr');
      const nameTd = el('td', { class: 'r-pillar-name', style: `color:${p.color}`, text: p.pillar });
      tr.appendChild(nameTd);
      tr.appendChild(el('td', { text: String(p.count) }));
      tr.appendChild(el('td', { text: fmtPct(p.avg) }));
      tr.appendChild(el('td', { text: p.top ? `${p.top.project} — ${fmtPct(p.top.pct)}` : '—' }));
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    cover.appendChild(table);

    root.appendChild(cover);

    // ---- Early wins ----
    const wins = state.rows.filter(r => r.pct >= 25).sort((a, b) => b.pct - a.pct);
    if (wins.length) {
      const sec = el('section', { class: 'r-page' });
      sec.appendChild(el('div', { class: 'r-section-title', text: `Early wins — initiatives at 25%+` }));
      const grid = el('div', { class: 'r-cards' });
      wins.forEach(r => {
        const card = el('div', { class: 'r-card' });
        card.appendChild(el('div', { class: 'r-card-top' }, [
          el('div', { class: 'r-card-name', text: r.project }),
          el('div', { class: 'r-card-pct', text: fmtPct(r.pct) })
        ]));
        card.appendChild(el('div', { class: 'r-card-meta', text: `${r.pillar}${r.pm ? ' · ' + r.pm : ''}` }));
        const bar = el('div', { class: 'r-card-bar' });
        const fill = el('div', { class: 'r-card-bar-fill' });
        fill.style.width = r.pct + '%';
        fill.style.background = pillarColor(r.pillar);
        bar.appendChild(fill);
        card.appendChild(bar);
        grid.appendChild(card);
      });
      sec.appendChild(grid);
      root.appendChild(sec);
    }

    // ---- Coming up / milestones ----
    if (state.milestones.length) {
      const sec = el('section', { class: 'r-page' });
      sec.appendChild(el('div', { class: 'r-section-title', text: 'Coming Up' }));
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
      const sec = el('section', { class: 'r-page r-pillar-section' });
      const head = el('div', { class: 'r-pillar-head', style: `border-color:${pAgg.color}` });
      head.appendChild(el('span', { class: 'r-pillar-swatch', style: `background:${pAgg.color}` }));
      head.appendChild(el('span', { class: 'r-pillar-head-name', text: pillar }));
      head.appendChild(el('span', { class: 'r-pillar-head-meta', text: `${items.length} initiative${items.length === 1 ? '' : 's'} · ${fmtPct(pAgg.avg)} avg completion` }));
      sec.appendChild(head);

      const dtable = el('table', { class: 'r-table r-detail-table' });
      const dthead = el('thead', {}, [el('tr', { style: `background:${pAgg.color}` }, [
        el('th', { text: 'Initiative' }), el('th', { text: 'Project Manager' }), el('th', { text: '%' }),
        el('th', { text: 'Status' }), el('th', { text: 'Key update' })
      ])]);
      dtable.appendChild(dthead);
      const dbody = el('tbody');
      items.forEach(r => {
        const s = statusFor(r.pct);
        const tr = el('tr');
        const nameTd = el('td', { class: 'r-detail-name' });
        nameTd.appendChild(el('div', { class: 'r-detail-project', text: r.project }));
        if (r.description) nameTd.appendChild(el('div', { class: 'r-detail-desc', text: r.description }));
        tr.appendChild(nameTd);
        tr.appendChild(el('td', { text: r.pm || '—' }));
        tr.appendChild(el('td', { class: 'r-detail-pct', text: fmtPct(r.pct) }));
        tr.appendChild(el('td', {}, [el('span', { class: 'r-status-pill ' + s.cls, text: s.label })]));
        tr.appendChild(el('td', { class: 'r-detail-update', text: r.updates || '—' }));
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

  function handleImportedRows(rows, sourceLabel) {
    if (!rows.length) {
      showImportStatus(`No usable rows found in ${sourceLabel}.`, true);
      return;
    }
    state.rows = state.rows.concat(rows);
    save();
    renderEditor();
    renderPillarDatalist();
    renderReport();
    showImportStatus(`Imported ${rows.length} initiative${rows.length === 1 ? '' : 's'} from ${sourceLabel}.`, false);
  }

  function init() {
    load();
    renderEditor();
    renderPillarDatalist();
    renderMilestones();
    renderSettingsForm();
    wireSettingsForm();
    renderReport();

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
      const rows = window.SAMPLE_DATA.map(d => newRow(d));
      state.rows = state.rows.concat(rows);
      if (!state.milestones.length) {
        state.milestones = [
          { when: 'End of May', text: 'Copilot Agent goes live on DDC SharePoint — all users gain instant guidance and search.' },
          { when: 'June', text: 'Data Warehouse Standards kickoff meetings begin across disciplines.' },
          { when: 'June', text: 'Autodesk IS Quality Copilot engagement launches via MCP integration.' },
          { when: 'July', text: 'Avail ENG rollout — full Engineering platform content go-live.' },
          { when: 'July', text: 'Enterprise-wide DDD automation tool deployment begins organization-wide.' }
        ];
      }
      if (!state.settings.summary) {
        state.settings.eyebrow = 'PROGRAM STATUS UPDATE';
        state.settings.title = 'Program & Strategy Update';
        state.settings.subtitle = 'Executive Leadership Summary — Sample Data';
        state.settings.summary = 'This is sample data loaded to demonstrate the report builder.\nReplace it by clearing all data and importing your own CSV or XLSX file.';
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
      state = { rows: [], milestones: [], settings: { eyebrow: '', title: '', subtitle: '', summary: '', contactName: '', contactEmail: '' } };
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
        pillar: 'Digital Platforms',
        project: 'Example Initiative Name',
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

    document.getElementById('btnImport').addEventListener('click', () => {
      document.getElementById('fileInput').click();
    });

    document.getElementById('fileInput').addEventListener('change', (e) => {
      const file = e.target.files && e.target.files[0];
      if (!file) return;
      const isXlsx = /\.xlsx?$/i.test(file.name);
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
