(function () {
  'use strict';

  var RESOURCE = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'Dehz_ServerOptimizer';

  var root = document.getElementById('root');
  var content = document.getElementById('content');
  var tabsEl = document.getElementById('tabs');
  var modal = document.getElementById('modal');
  var toastEl = document.getElementById('toast');

  var currentTab = 'overview';
  var cache = {};
  var meta = null;
  var timer = null;
  var expanded = {};
  var sortState = {};
  var logFilters = { module: '', level: '' };
  var toastTimer = null;

  /* ------------------------------------------------------------------ */

  function post(name, data) {
    return fetch('https://' + RESOURCE + '/' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).catch(function () { });
  }

  function esc(value) {
    if (value === null || value === undefined) return '';
    return String(value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function num(value, digits) {
    if (value === null || value === undefined || isNaN(value)) return '--';
    var n = Number(value);
    if (digits === undefined) digits = 0;
    return n.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
  }

  function bytes(value) {
    if (!value) return '0 B';
    var units = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    var n = Number(value);
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return n.toFixed(i === 0 ? 0 : 1) + ' ' + units[i];
  }

  function duration(ms) {
    if (!ms) return '0s';
    var s = Math.floor(ms / 1000);
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    if (h > 0) return h + 'h ' + m + 'm';
    if (m > 0) return m + 'm ' + (s % 60) + 's';
    return s + 's';
  }

  function clockTime(epoch) {
    if (!epoch) return '--';
    var d = new Date(epoch * 1000);
    return d.toTimeString().slice(0, 8);
  }

  function toast(message) {
    toastEl.textContent = message;
    toastEl.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.hidden = true; }, 4200);
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        toast('Copied to clipboard');
      }, fallbackCopy.bind(null, text));
      return;
    }
    fallbackCopy(text);
  }

  function fallbackCopy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try { document.execCommand('copy'); toast('Copied to clipboard'); }
    catch (e) { toast('Could not copy - select the line manually'); }
    document.body.removeChild(area);
  }

  function confirmAction(title, body, onConfirm) {
    document.getElementById('modalTitle').textContent = title;
    document.getElementById('modalBody').textContent = body;
    modal.hidden = false;

    var confirmBtn = document.getElementById('modalConfirm');
    var cancelBtn = document.getElementById('modalCancel');

    function cleanup() {
      modal.hidden = true;
      confirmBtn.removeEventListener('click', accept);
      cancelBtn.removeEventListener('click', cleanup);
    }
    function accept() { cleanup(); onConfirm(); }

    confirmBtn.addEventListener('click', accept);
    cancelBtn.addEventListener('click', cleanup);
  }

  /* ------------------------------------------------------------------ */

  function severityPill(severity) {
    var cls = severity === 'critical' ? 'pill-critical'
      : (severity === 'warning' || severity === 'major') ? 'pill-warning'
        : (severity === 'severe') ? 'pill-critical'
          : 'pill-info';
    return '<span class="pill ' + cls + '">' + esc(severity) + '</span>';
  }

  function panel(title, sub, body, extraClass) {
    return '<section class="panel ' + (extraClass || '') + '">'
      + '<div class="panel-head"><span class="panel-title">' + esc(title) + '</span>'
      + (sub ? '<span class="panel-sub">' + esc(sub) + '</span>' : '')
      + '</div>' + body + '</section>';
  }

  function tile(label, value, note, tone) {
    return '<div class="panel"><div class="panel-body"><div class="tile">'
      + '<span class="tile-label">' + esc(label) + '</span>'
      + '<span class="tile-value' + (tone ? ' is-' + tone : '') + '">' + value + '</span>'
      + (note ? '<span class="tile-note">' + esc(note) + '</span>' : '')
      + '</div></div></div>';
  }

  function sparkline(values, baseline) {
    if (!values || values.length < 2) {
      return '<div class="panel-body"><span class="tile-note">not enough samples yet</span></div>';
    }

    var w = 600, h = 56, pad = 2;
    var max = Math.max.apply(null, values);
    if (baseline && baseline > max) max = baseline;
    max = Math.max(max, 10) * 1.1;

    var step = (w - pad * 2) / (values.length - 1);
    var pts = values.map(function (v, i) {
      var x = pad + i * step;
      var y = h - pad - ((v / max) * (h - pad * 2));
      return x.toFixed(1) + ',' + y.toFixed(1);
    });

    var area = 'M' + pad + ',' + (h - pad) + ' L' + pts.join(' L') + ' L' + (w - pad) + ',' + (h - pad) + ' Z';
    var baseY = baseline ? (h - pad - ((baseline / max) * (h - pad * 2))) : null;

    return '<div class="panel-body">'
      + '<svg class="spark" viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none" role="img" aria-label="server tick gap">'
      + '<path class="spark-area" d="' + area + '"/>'
      + '<polyline class="spark-line" points="' + pts.join(' ') + '"/>'
      + (baseY !== null ? '<line class="spark-baseline" x1="' + pad + '" y1="' + baseY.toFixed(1) + '" x2="' + (w - pad) + '" y2="' + baseY.toFixed(1) + '"/>' : '')
      + '</svg>'
      + '<div class="tile-note">peak ' + num(Math.max.apply(null, values)) + 'ms'
      + (baseline ? ' &middot; dashed line = ' + baseline + 'ms normal tick interval' : '') + '</div>'
      + '</div>';
  }

  function capabilityStrip(caps) {
    if (!caps) return '';
    var labels = {
      entityPool: 'entity list',
      orphanMode: 'orphan mode',
      entityScript: 'entity attribution',
      entitiesInRadius: 'radius query',
      peerStatistics: 'peer statistics',
      convarListener: 'convar events',
      consoleListener: 'console events',
      readdir: 'filesystem scan',
      perf: 'metrics endpoint',
      oxmysql: 'oxmysql',
      oxlib: 'ox_lib'
    };

    var out = '';
    Object.keys(labels).forEach(function (key) {
      var ok = caps[key] === true;
      out += '<span class="pill ' + (ok ? 'pill-ok' : 'pill-muted') + '">' + esc(labels[key]) + (ok ? '' : ' off') + '</span>';
    });
    return '<div class="panel-body"><div class="caps">' + out + '</div>'
      + '<div class="tile-note" style="margin-top:8px">Anything marked "off" is not available on this server build. Features that depend on it are disabled rather than faked.</div></div>';
  }

  function sortRows(key, rows, accessor) {
    var st = sortState[key];
    if (!st) return rows;
    var dir = st.dir === 'asc' ? 1 : -1;
    return rows.slice().sort(function (a, b) {
      var av = accessor(a, st.col), bv = accessor(b, st.col);
      if (typeof av === 'string' || typeof bv === 'string') {
        return String(av).localeCompare(String(bv)) * dir;
      }
      return ((av || 0) - (bv || 0)) * dir;
    });
  }

  function sortHeader(key, col, label, cls) {
    var st = sortState[key];
    var arrow = (st && st.col === col) ? (st.dir === 'asc' ? ' &uarr;' : ' &darr;') : '';
    return '<th class="sortable ' + (cls || '') + '" data-sortkey="' + esc(key) + '" data-sortcol="' + esc(col) + '">'
      + esc(label) + arrow + '</th>';
  }

  /* ------------------------------------------------------------------ */

  function renderOverview(d) {
    var e = d.entities || {};
    var w = d.windows || {};
    var sweeper = d.sweeper || {};
    var comp = (meta && meta.components) || {};

    var html = '<div class="grid grid-4">';
    html += tile('Players', num(e.players));
    html += tile('Entities', num(e.total), (e.vehicles || 0) + ' veh / ' + (e.peds || 0) + ' ped / ' + (e.objects || 0) + ' obj');
    html += tile('Entities per player', num(e.ratio, 1), null, (e.ratio > 80 ? 'crit' : e.ratio > 40 ? 'warn' : 'ok'));
    html += tile('Critical config findings', num(d.unresolvedCritical),
      num(d.unresolvedWarning) + ' warnings', d.unresolvedCritical > 0 ? 'crit' : 'ok');
    html += '</div>';

    html += '<div class="grid grid-2" style="margin-top:12px">';

    html += panel('Server tick gap', 'main thread, last ' + ((d.sparkline || []).length) + 's',
      sparkline(d.sparkline, d.baselineMs || 50));

    var bars = '<div class="panel-body"><div class="bars">';
    [['Config audit', comp.audit], ['Hitches', comp.hitches], ['Entity load', comp.entities], ['Resources', comp.resources]]
      .forEach(function (row) {
        var v = Math.max(0, Math.min(100, row[1] || 0));
        bars += '<div class="bar-row"><span class="bar-name">' + esc(row[0]) + '</span>'
          + '<span class="bar-track"><span class="bar-fill" style="width:' + v + '%"></span></span>'
          + '<span class="bar-val">' + num(v) + '</span></div>';
      });
    bars += '</div></div>';
    html += panel('Health breakdown', 'weighted 30/30/20/20', bars);

    html += '</div>';

    var rows = '';
    ['1m', '5m', '1h'].forEach(function (key) {
      var s = w[key];
      if (!s) return;
      rows += '<tr><td class="mono">' + key + '</td>'
        + '<td class="num">' + num(s.p50) + '</td>'
        + '<td class="num">' + num(s.p95) + '</td>'
        + '<td class="num">' + num(s.p99) + '</td>'
        + '<td class="num">' + num(s.max) + '</td>'
        + '<td class="num">' + num(s.count) + '</td>'
        + '<td>' + (s.approximate ? '<span class="pill pill-muted">approx</span>' : '') + '</td></tr>';
    });

    var perfRows = '';
    if (d.perf) {
      Object.keys(d.perf).forEach(function (thread) {
        var p = d.perf[thread];
        if (!p || !p.window) return;
        perfRows += '<tr><td class="mono">' + esc(thread) + '</td>'
          + '<td class="num">' + num(p.window.meanMs, 2) + '</td>'
          + '<td class="num">' + num(p.window.p50, 1) + '</td>'
          + '<td class="num">' + num(p.window.p95, 1) + '</td>'
          + '<td class="num">' + num(p.window.p99, 1) + '</td>'
          + '<td class="num">' + num(p.window.ticks) + '</td></tr>';
      });
    }

    html += '<div class="grid grid-2" style="margin-top:12px">';
    html += panel('Tick gap percentiles', 'milliseconds between server frames',
      '<div class="panel-body tight"><div class="scroll-x"><table><thead><tr>'
      + '<th>window</th><th class="num">p50</th><th class="num">p95</th><th class="num">p99</th><th class="num">max</th><th class="num">samples</th><th></th>'
      + '</tr></thead><tbody>' + (rows || '<tr><td colspan="7" style="color:var(--text-faint)">collecting</td></tr>') + '</tbody></table></div></div>');

    html += panel('Measured tick time', perfRows ? 'from the server /perf endpoint' : 'endpoint unavailable',
      perfRows
        ? '<div class="panel-body tight"><div class="scroll-x"><table><thead><tr>'
        + '<th>thread</th><th class="num">mean</th><th class="num">p50</th><th class="num">p95</th><th class="num">p99</th><th class="num">ticks</th>'
        + '</tr></thead><tbody>' + perfRows + '</tbody></table></div></div>'
        : '<div class="panel-body"><div class="note">The server metrics endpoint is not reachable, so measured per-thread tick time is unavailable. Hitch detection is running on the console and timer sources instead.</div></div>');
    html += '</div>';

    var sweepKv = '<div class="panel-body"><dl class="kv">'
      + '<dt>operating mode</dt><dd>' + esc(meta.mode) + '</dd>'
      + '<dt>effective action</dt><dd>' + esc(sweeper.action || '--') + '</dd>'
      + '<dt>configured action</dt><dd>' + esc(sweeper.configuredAction || '--') + '</dd>'
      + '<dt>dry run</dt><dd>' + (sweeper.dryRun ? 'yes' : 'no') + '</dd>'
      + '<dt>orphan mode native</dt><dd>' + (sweeper.orphanModeAvailable ? 'available' : 'unavailable') + '</dd>'
      + '<dt>plate protection</dt><dd>' + (sweeper.plateLookup ? (sweeper.plateLookup.applicable
        ? (num(sweeper.plateLookup.count) + ' plates' + (sweeper.plateLookup.ok ? '' : ' (lookup failed)'))
        : 'standalone, none') : '--') + '</dd>'
      + '<dt>swept so far</dt><dd>' + num(sweeper.totals ? sweeper.totals.reported : 0) + ' reported / '
      + num(sweeper.totals ? sweeper.totals.orphaned : 0) + ' orphaned / '
      + num(sweeper.totals ? sweeper.totals.deleted : 0) + ' deleted</dd>'
      + '</dl>'
      + (sweeper.liveBlockedByPlates
        ? '<div class="note is-warn" style="margin-top:10px">Live sweeping is blocked: the owned-vehicle plate lookup failed and requirePlateLookup is on.</div>' : '')
      + '</div>';

    html += '<div class="grid grid-2" style="margin-top:12px">';
    html += panel('Entity sweeper', sweeper.enabled ? 'armed' : 'disabled', sweepKv);
    html += panel('Capabilities on this build', meta.capabilities ? ('fxserver ' + (meta.capabilities.serverVersion || '')) : '', capabilityStrip(meta.capabilities));
    html += '</div>';

    if (d.culling && d.culling.enabled) {
      html += '<div style="margin-top:12px">' + panel('Distance culling', 'deprecated',
        '<div class="panel-body"><div class="note is-warn">' + esc(d.culling.note) + '</div></div>') + '</div>';
    }

    return html;
  }

  /* ------------------------------------------------------------------ */

  function renderEntities(d) {
    var counts = d.counts || {};
    var status = d.status || {};

    var html = '<div class="grid grid-4">';
    html += tile('Vehicles', num(counts.vehicles));
    html += tile('Peds', num(counts.peds));
    html += tile('Objects', num(counts.objects));
    html += tile('Per player', num(d.ratio, 1));
    html += '</div>';

    var controls = '<div class="panel-body"><div class="controls">'
      + '<select id="sweepCategory"><option value="all">all categories</option>'
      + '<option value="vehicles">vehicles</option><option value="peds">peds</option><option value="objects">objects</option></select>'
      + '<label class="switch"><input type="checkbox" id="sweepLive"><span class="switch-track"></span>'
      + '<span class="switch-label">live run</span></label>'
      + '<button class="btn" id="runSweep" type="button">Run sweep</button>'
      + '<button class="btn btn-small" id="rescan" type="button">Rescan entities now</button>'
      + '</div>';

    if (meta.mode !== 'active') {
      controls += '<div class="note" style="margin-top:10px">Operating mode is <b>monitor</b>. A live run will still be reported as a dry run - nothing can be deleted or changed until Config.Mode is set to "active" in config.lua.</div>';
    } else if (status.dryRun) {
      controls += '<div class="note" style="margin-top:10px">Config.Sweeper.dryRun is true, so a live run will still only report.</div>';
    } else {
      controls += '<div class="note is-warn" style="margin-top:10px">Live action is armed: this sweeper will <b>' + esc(status.configuredAction) + '</b> entities that fail every check.</div>';
    }
    controls += '</div>';

    html += '<div style="margin-top:12px">' + panel('Run a sweep', 'every run is written to the log with your identifier', controls) + '</div>';

    var byRes = (d.byResource || []).map(function (r) {
      return '<tr><td class="mono">' + esc(r.resource) + '</td><td class="num">' + num(r.count) + '</td></tr>';
    }).join('');

    html += '<div class="grid grid-2" style="margin-top:12px">';
    html += panel('Entities by creating resource', 'which resource made them',
      '<div class="panel-body tight"><div class="scroll-y"><table><thead><tr><th>resource</th><th class="num">entities</th></tr></thead><tbody>'
      + (byRes || '<tr><td colspan="2" style="color:var(--text-faint)">no attribution available</td></tr>')
      + '</tbody></table></div></div>');

    var models = '';
    ['vehicles', 'peds', 'objects'].forEach(function (cat) {
      var list = (d.topModels && d.topModels[cat]) || [];
      list.slice(0, 12).forEach(function (m) {
        models += '<tr><td class="mono">' + esc(cat) + '</td><td class="mono">' + esc(m.model) + '</td><td class="num">' + num(m.count) + '</td></tr>';
      });
    });

    html += panel('Top models by instance count', 'model hashes - the server cannot resolve names',
      '<div class="panel-body tight"><div class="scroll-y"><table><thead><tr><th>category</th><th>model hash</th><th class="num">count</th></tr></thead><tbody>'
      + (models || '<tr><td colspan="3" style="color:var(--text-faint)">no entities indexed</td></tr>')
      + '</tbody></table></div></div>');
    html += '</div>';

    var history = (d.history || []).map(function (h) {
      return '<tr><td class="mono">' + clockTime(h.at) + '</td>'
        + '<td>' + esc(h.category) + '</td>'
        + '<td>' + (h.dryRun ? '<span class="pill pill-muted">dry run</span>' : '<span class="pill pill-warning">' + esc(h.action) + '</span>') + '</td>'
        + '<td class="num">' + num(h.scanned) + '</td>'
        + '<td class="num">' + num(h.eligible) + '</td>'
        + '<td class="num">' + num(h.acted) + '</td>'
        + '<td class="num">' + num(h.protected) + '</td>'
        + '<td class="num">' + num(h.durationMs) + 'ms</td>'
        + '<td>' + (h.capped ? '<span class="pill pill-critical">capped</span>' : '') + '</td>'
        + '<td class="mono">' + esc(h.actor || '') + '</td></tr>';
    }).join('');

    html += '<div style="margin-top:12px">' + panel('Sweep history', 'newest first',
      '<div class="panel-body tight"><div class="scroll-x"><table><thead><tr>'
      + '<th>time</th><th>category</th><th>action</th><th class="num">scanned</th><th class="num">eligible</th>'
      + '<th class="num">acted</th><th class="num">protected</th><th class="num">took</th><th></th><th>by</th>'
      + '</tr></thead><tbody>' + (history || '<tr><td colspan="10" style="color:var(--text-faint)">no sweeps yet</td></tr>')
      + '</tbody></table></div></div>') + '</div>';

    return html;
  }

  /* ------------------------------------------------------------------ */

  function renderResources(d) {
    var html = '<div class="note">' + esc(d.note)
      + ' Nothing on a FiveM server exposes live per-resource CPU cost, so this ranking is a judgement about code shape, not a measurement.</div>';

    if (d.progress && d.progress.running) {
      html += '<div class="note" style="margin-top:10px">Analysis running: ' + num(d.progress.current) + ' of '
        + num(d.progress.total) + ' &mdash; ' + esc(d.progress.resource || '') + '</div>';
    }

    html += '<div class="controls" style="margin-top:12px">'
      + '<button class="btn" id="runAnalyze" type="button">Re-run analysis</button>'
      + '<button class="btn" id="runExport" type="button">Export health report</button>';

    if (d.profiler && d.profiler.status && d.profiler.status.enabled) {
      html += '<button class="btn btn-danger" id="runProfile" type="button">Run profiler ('
        + num(d.profiler.status.defaultFrames) + ' frames)</button>';
    }
    html += '<span class="tile-note">' + (d.streamMeasured
      ? ('stream assets measured: ' + bytes(d.totalStreamBytes))
      : 'stream weight not measurable on this build') + '</span>';
    html += '</div>';

    var rows = sortRows('resources', d.resources || [], function (r, col) {
      if (col === 'name') return r.name;
      if (col === 'score') return r.score;
      if (col === 'findings') return r.findingCount;
      if (col === 'lines') return r.stats.lines;
      if (col === 'stream') return r.streamBytes;
      return r.score;
    }).map(function (r) {
      var isOpen = expanded['res:' + r.name];
      var body = '<tr class="is-clickable" data-expand="res:' + esc(r.name) + '">'
        + '<td class="mono">' + esc(r.name) + (r.partial ? ' <span class="pill pill-muted">manifest only</span>' : '')
        + (r.escrowed ? ' <span class="pill pill-muted">escrow</span>' : '') + '</td>'
        + '<td class="num">' + num(r.score) + '</td>'
        + '<td class="num">' + num(r.findingCount) + '</td>'
        + '<td class="num">' + num(r.stats.files) + '</td>'
        + '<td class="num">' + num(r.stats.lines) + '</td>'
        + '<td class="num">' + num(r.stats.busyWait) + '</td>'
        + '<td class="num">' + num(r.stats.unsafeEvents) + '</td>'
        + '<td class="num">' + num(r.stats.broadcasts) + '</td>'
        + '<td class="num">' + bytes(r.streamBytes) + '</td></tr>';

      if (isOpen) {
        var findings = (r.findings || []).map(function (f) {
          return '<div class="finding"><div class="finding-head">'
            + '<span class="finding-loc">' + esc(f.file) + ':' + num(f.line) + '</span>'
            + '<span class="finding-label">' + esc(f.label) + '</span>'
            + '<span class="pill pill-muted">' + esc(f.kind) + '</span>'
            + (f.side && f.side !== 'unknown' ? '<span class="pill pill-muted">' + esc(f.side) + '</span>' : '')
            + (f.heuristic ? '<span class="pill pill-info">heuristic</span>' : '')
            + '</div>' + (f.note ? '<div class="finding-note">' + esc(f.note) + '</div>' : '') + '</div>';
        }).join('');

        body += '<tr class="detail-row"><td colspan="9"><div class="detail-inner">'
          + (findings || '<span class="tile-note">no findings</span>')
          + (r.findingsTruncated ? '<div class="tile-note" style="margin-top:8px">Only the first ' + num((r.findings || []).length) + ' findings are shown.</div>' : '')
          + '</div></td></tr>';
      }

      return body;
    }).join('');

    html += '<div style="margin-top:12px">' + panel('Estimated risk ranking', num(d.scanned) + ' resources scanned in ' + num(d.durationMs) + 'ms',
      '<div class="panel-body tight"><div class="scroll-x"><table><thead><tr>'
      + sortHeader('resources', 'name', 'resource')
      + sortHeader('resources', 'score', 'est. risk', 'num')
      + sortHeader('resources', 'findings', 'findings', 'num')
      + '<th class="num">files</th>'
      + sortHeader('resources', 'lines', 'lines', 'num')
      + '<th class="num">busy loops</th><th class="num">unsafe events</th><th class="num">broadcasts</th>'
      + sortHeader('resources', 'stream', 'stream', 'num')
      + '</tr></thead><tbody>' + (rows || '<tr><td colspan="9" style="color:var(--text-faint)">no analysis yet</td></tr>')
      + '</tbody></table></div></div>') + '</div>';

    var unscannable = (d.unscannable || []).map(function (r) {
      return '<tr><td class="mono">' + esc(r.name) + '</td><td>' + esc(r.reason) + '</td>'
        + '<td class="num">' + bytes(r.streamBytes) + '</td></tr>';
    }).join('');

    html += '<div style="margin-top:12px">' + panel('Unscannable resources', 'listed separately so the ranking above is not misleading',
      '<div class="panel-body tight"><div class="scroll-y"><table><thead><tr><th>resource</th><th>reason</th><th class="num">stream</th></tr></thead><tbody>'
      + (unscannable || '<tr><td colspan="3" style="color:var(--text-faint)">none</td></tr>')
      + '</tbody></table></div></div>') + '</div>';

    if (d.profiler && d.profiler.status && d.profiler.status.enabled) {
      var p = d.profiler.report;
      var prows = p ? (p.resources || []).slice(0, 25).map(function (r) {
        return '<tr><td class="mono">' + esc(r.resource) + '</td>'
          + '<td class="num">' + num(r.ms, 2) + '</td>'
          + '<td class="num">' + num(r.share, 2) + '%</td>'
          + '<td class="num">' + num(r.msPerCall, 4) + '</td>'
          + '<td class="num">' + num(r.calls) + '</td>'
          + '<td class="num">' + num(r.ticks) + '</td>'
          + '<td class="num">' + num(r.events) + '</td></tr>';
      }).join('') : '';

      html += '<div style="margin-top:12px">' + panel('Measured per-resource time',
        p ? ('sample of ' + num(p.frames) + ' frames, ' + num(p.wallMs, 1) + 'ms of server time') : (d.profiler.status.stage || 'idle'),
        '<div class="panel-body tight">'
        + '<div style="padding:12px"><div class="note">These are <b>measured</b> microsecond timings from the server\'s own profiler, not estimates. They are a short sample, not a live monitor.'
        + (d.profiler.status.lastError ? ' Last attempt failed: ' + esc(d.profiler.status.lastError) : '') + '</div></div>'
        + '<div class="scroll-x"><table><thead><tr><th>resource</th><th class="num">total ms</th><th class="num">share</th>'
        + '<th class="num">ms/call</th><th class="num">calls</th><th class="num">ticks</th><th class="num">events</th></tr></thead><tbody>'
        + (prows || '<tr><td colspan="7" style="color:var(--text-faint)">no profile recorded yet</td></tr>')
        + '</tbody></table></div></div>') + '</div>';
    }

    return html;
  }

  /* ------------------------------------------------------------------ */

  function renderAudit(d) {
    var html = '<div class="controls">'
      + '<button class="btn" id="runAudit" type="button">Re-run audit</button>'
      + '<span class="tile-note">' + num(d.counts.critical) + ' critical &middot; ' + num(d.counts.warning)
      + ' warning &middot; ' + num(d.counts.info) + ' info</span>';
    if (d.autoApplyEnabled) {
      html += '<span class="pill pill-warning">auto-apply enabled</span>';
    }
    html += '</div>';

    ['critical', 'warning', 'info'].forEach(function (sev) {
      var group = (d.findings || []).filter(function (f) { return f.severity === sev; });
      if (!group.length) return;

      var body = '<div class="panel-body tight">' + group.map(function (f) {
        return '<div class="finding"><div class="finding-head">'
          + severityPill(f.severity)
          + '<span class="finding-loc">' + esc(f.key) + '</span>'
          + '<span class="finding-label">current <b class="mono">' + esc(f.current) + '</b> &rarr; recommended <b class="mono">' + esc(f.recommended) + '</b></span>'
          + (f.runtimeSettable ? '' : '<span class="pill pill-muted">server.cfg only</span>')
          + (f.deprecated ? '<span class="pill pill-muted">removed from fxserver</span>' : '')
          + '</div>'
          + '<div class="finding-note">' + esc(f.impact) + '</div>'
          + '<div class="copy"><code>' + esc(f.line) + '</code>'
          + '<button class="btn btn-small" data-copy="' + esc(f.line) + '" type="button">copy</button></div>'
          + '</div>';
      }).join('') + '</div>';

      html += '<div style="margin-top:12px">' + panel(sev + ' findings', num(group.length) + ' items', body) + '</div>';
    });

    if (!(d.findings || []).length) {
      html += '<div style="margin-top:12px">' + panel('Findings', 'none',
        '<div class="panel-body"><div class="note">No configuration findings. Either your server.cfg is in good shape or the audit has not run yet.</div></div>') + '</div>';
    }

    var adv = (d.advisories || []).map(function (a) {
      return '<tr><td class="mono">' + esc(a.key) + '</td><td class="mono">' + esc(a.current) + '</td><td>' + esc(a.impact) + '</td></tr>';
    }).join('');

    html += '<div style="margin-top:12px">' + panel('Trade-offs and context', 'reported for information, not as problems',
      '<div class="panel-body tight"><div class="scroll-x"><table><thead><tr><th>convar</th><th>current</th><th>what it does</th></tr></thead><tbody>'
      + (adv || '<tr><td colspan="3" style="color:var(--text-faint)">none</td></tr>') + '</tbody></table></div></div>') + '</div>';

    if ((d.missing || []).length) {
      html += '<div style="margin-top:12px">' + panel('Not present on this build', num(d.missing.length) + ' convars',
        '<div class="panel-body"><div class="tile-note mono">' + esc(d.missing.join(', ')) + '</div>'
        + '<div class="tile-note" style="margin-top:6px">These were skipped rather than reported as findings, because they do not exist on the FXServer build you are running.</div></div>') + '</div>';
    }

    return html;
  }

  /* ------------------------------------------------------------------ */

  function renderHitches(d) {
    var r = d.report || {};
    var counts = r.counts || {};

    var html = '<div class="grid grid-4">';
    html += tile('Minor', num(counts.minor));
    html += tile('Major', num(counts.major), null, counts.major > 0 ? 'warn' : null);
    html += tile('Severe', num(counts.severe), null, counts.severe > 0 ? 'crit' : null);
    html += tile('Baseline tick', num(r.baselineMs) + 'ms', 'normal gap between server frames');
    html += '</div>';

    html += '<div style="margin-top:12px">' + panel('Tick gap', 'per-second maxima', sparkline(d.sparkline, r.baselineMs)) + '</div>';

    html += '<div style="margin-top:12px" class="note is-warn">Thresholds ship <b>uncalibrated</b>: minor '
      + num(r.thresholds ? r.thresholds.minor : 0) + 'ms, major ' + num(r.thresholds ? r.thresholds.major : 0)
      + 'ms, severe ' + num(r.thresholds ? r.thresholds.severe : 0) + 'ms. The server engine reports its own hitches above '
      + num(r.engineThresholds ? r.engineThresholds.svMain : 150) + 'ms on the main thread and '
      + num(r.engineThresholds ? r.engineThresholds.svSync : 100) + 'ms on the sync thread. Tune these against your own history.</div>';

    var worst = (d.worst || []).map(function (h, i) {
      var key = 'hitch:' + i;
      var row = '<tr class="is-clickable" data-expand="' + key + '">'
        + '<td class="num">' + num(h.duration) + 'ms</td>'
        + '<td>' + severityPill(h.severity) + '</td>'
        + '<td class="mono">' + esc(h.thread) + '</td>'
        + '<td class="mono">' + esc(h.source) + '</td>'
        + '<td class="mono">' + clockTime(h.at) + '</td>'
        + '<td class="num">' + num(h.context ? h.context.players : 0) + '</td>'
        + '<td class="num">' + num(h.context ? h.context.totalEntities : 0) + '</td></tr>';

      if (expanded[key] && h.context) {
        var c = h.context;
        row += '<tr class="detail-row"><td colspan="7"><div class="detail-inner"><dl class="kv">'
          + '<dt>vehicles / peds / objects</dt><dd>' + num(c.vehicles) + ' / ' + num(c.peds) + ' / ' + num(c.objects) + '</dd>'
          + '<dt>entities per player</dt><dd>' + num(c.ratio, 1) + '</dd>'
          + '<dt>uptime</dt><dd>' + duration(c.uptime) + '</dd>'
          + '<dt>state bag writes/s</dt><dd>' + num(c.stateBagRate, 1) + '</dd>'
          + '<dt>sweep running</dt><dd>' + (c.sweepRunning ? 'yes' : 'no') + '</dd>'
          + '<dt>avg ping</dt><dd>' + num(c.avgPing) + ' ms</dd>'
          + '<dt>avg packet loss</dt><dd>' + num(c.avgPacketLoss, 2) + ' %</dd>'
          + '</dl></div></td></tr>';
      }
      return row;
    }).join('');

    html += '<div style="margin-top:12px">' + panel('Worst hitches', 'click a row for the snapshot',
      '<div class="panel-body tight"><div class="scroll-x"><table><thead><tr>'
      + '<th class="num">duration</th><th>severity</th><th>thread</th><th>source</th><th>time</th>'
      + '<th class="num">players</th><th class="num">entities</th></tr></thead><tbody>'
      + (worst || '<tr><td colspan="7" style="color:var(--text-faint)">no hitches recorded</td></tr>')
      + '</tbody></table></div></div>') + '</div>';

    var recent = (d.history || []).slice(0, 40).map(function (h) {
      return '<tr><td class="mono">' + clockTime(h.at) + '</td><td class="num">' + num(h.duration) + 'ms</td>'
        + '<td>' + severityPill(h.severity) + '</td><td class="mono">' + esc(h.thread) + '</td>'
        + '<td class="mono">' + esc(h.source) + '</td>'
        + '<td class="num">' + num(h.context ? h.context.players : 0) + '</td></tr>';
    }).join('');

    var consoleData = d.console || {};
    var vol = (consoleData.volume || []).map(function (v) {
      return '<tr><td class="mono">' + esc(v.resource) + '</td><td class="num">' + num(v.lines) + '</td></tr>';
    }).join('');
    var errs = (consoleData.errors || []).map(function (v) {
      return '<tr><td class="mono">' + esc(v.resource) + '</td><td class="num">' + num(v.errors) + '</td></tr>';
    }).join('');

    html += '<div class="grid grid-2" style="margin-top:12px">';
    html += panel('Recent hitches', 'newest first',
      '<div class="panel-body tight"><div class="scroll-y"><table><thead><tr><th>time</th><th class="num">duration</th>'
      + '<th>severity</th><th>thread</th><th>source</th><th class="num">players</th></tr></thead><tbody>'
      + (recent || '<tr><td colspan="6" style="color:var(--text-faint)">none</td></tr>') + '</tbody></table></div></div>');

    html += panel('Console activity', 'lines and script errors seen since start',
      '<div class="panel-body tight"><div class="scroll-y"><table><thead><tr><th>resource</th><th class="num">script errors</th></tr></thead><tbody>'
      + (errs || '<tr><td colspan="2" style="color:var(--text-faint)">none</td></tr>')
      + '</tbody></table><table><thead><tr><th>resource</th><th class="num">console lines</th></tr></thead><tbody>'
      + (vol || '<tr><td colspan="2" style="color:var(--text-faint)">none</td></tr>')
      + '</tbody></table></div></div>');
    html += '</div>';

    return html;
  }

  /* ------------------------------------------------------------------ */

  function renderLogs(d) {
    var options = ['<option value="">all modules</option>'].concat((d.modules || []).map(function (m) {
      return '<option value="' + esc(m) + '"' + (logFilters.module === m ? ' selected' : '') + '>' + esc(m) + '</option>';
    })).join('');

    var levels = ['', 'debug', 'info', 'warn', 'error'].map(function (l) {
      return '<option value="' + l + '"' + (logFilters.level === l ? ' selected' : '') + '>' + (l || 'all levels') + '</option>';
    }).join('');

    var html = '<div class="controls">'
      + '<select id="logModule">' + options + '</select>'
      + '<select id="logLevel">' + levels + '</select>'
      + '<span class="tile-note">webhooks sent ' + num(d.webhook ? d.webhook.sent : 0)
      + ', failed ' + num(d.webhook ? d.webhook.failed : 0)
      + ' &middot; database ' + (d.database && d.database.available ? 'connected' : ('off' + (d.database && d.database.reason ? ' (' + esc(d.database.reason) + ')' : '')))
      + '</span></div>';

    var rows = (d.entries || []).map(function (e) {
      return '<tr><td class="mono">' + clockTime(e.at) + '</td>'
        + '<td>' + severityPill(e.level === 'warn' ? 'warning' : e.level === 'error' ? 'critical' : 'info') + '</td>'
        + '<td class="mono">' + esc(e.module) + '</td>'
        + '<td>' + esc(e.message) + '</td></tr>';
    }).join('');

    html += '<div style="margin-top:12px">' + panel('Module activity', num((d.entries || []).length) + ' lines',
      '<div class="panel-body tight"><div class="scroll-x" style="max-height:600px;overflow-y:auto"><table><thead><tr>'
      + '<th>time</th><th>level</th><th>module</th><th>message</th></tr></thead><tbody>'
      + (rows || '<tr><td colspan="4" style="color:var(--text-faint)">nothing logged yet</td></tr>')
      + '</tbody></table></div></div>') + '</div>';

    return html;
  }

  /* ------------------------------------------------------------------ */

  var renderers = {
    overview: renderOverview,
    entities: renderEntities,
    resources: renderResources,
    audit: renderAudit,
    hitches: renderHitches,
    logs: renderLogs
  };

  function renderMeta() {
    if (!meta) return;
    document.getElementById('serverName').textContent = meta.serverName || '';
    document.getElementById('healthScore').textContent = meta.health === undefined ? '--' : meta.health;

    var pill = document.getElementById('modePill');
    var value = document.getElementById('modeValue');
    value.textContent = (meta.mode || '').toUpperCase();
    pill.className = 'mode ' + (meta.mode === 'active' ? 'is-active' : 'is-monitor');

    document.getElementById('tabsMeta').textContent =
      meta.framework + ' · ' + num(meta.players) + ' players · up ' + duration(meta.uptimeMs);

    document.getElementById('statusbar').innerHTML =
      '<span><b>mode</b> ' + esc(meta.mode) + '</span>'
      + '<span><b>sweeper</b> ' + esc(meta.sweeperAction) + (meta.dryRun ? ' (dry run)' : '') + '</span>'
      + '<span><b>framework</b> ' + esc(meta.framework) + '</span>'
      + '<span><b>onesync</b> ' + esc(meta.capabilities ? meta.capabilities.oneSync : '?') + '</span>'
      + '<span><b>refresh</b> ' + num(meta.refreshInterval) + 'ms</span>';
  }

  function render() {
    var payload = cache[currentTab];
    if (!payload) {
      content.innerHTML = '<div class="empty">Loading&hellip;</div>';
      return;
    }
    var fn = renderers[currentTab] || renderOverview;
    try {
      content.innerHTML = fn(payload);
    } catch (err) {
      content.innerHTML = '<div class="empty">Could not render this tab: ' + esc(err.message) + '</div>';
    }
  }

  function requestRefresh() {
    var filters = currentTab === 'logs' ? logFilters : null;
    post('refresh', { tab: currentTab, filters: filters });
  }

  function startTimer() {
    if (timer) clearInterval(timer);
    var interval = (meta && meta.refreshInterval) || 2000;
    if (interval < 1000) interval = 1000;
    timer = setInterval(requestRefresh, interval);
  }

  function stopTimer() {
    if (timer) clearInterval(timer);
    timer = null;
  }

  function show() {
    root.hidden = false;
    startTimer();
  }

  function hide() {
    root.hidden = true;
    stopTimer();
    post('close');
  }

  /* ------------------------------------------------------------------ */

  window.addEventListener('message', function (event) {
    var payload = event.data;
    if (!payload || !payload.type) return;

    if (payload.type === 'open') { show(); return; }
    if (payload.type === 'close') { root.hidden = true; stopTimer(); return; }

    if (payload.type === 'data' && payload.payload) {
      meta = payload.payload.meta || meta;
      cache[payload.payload.tab] = payload.payload.data;
      renderMeta();
      if (payload.payload.tab === currentTab) render();
      if (root.hidden) show();
      return;
    }

    if (payload.type === 'action' && payload.payload) {
      var a = payload.payload;
      if (a.action === 'sweep') {
        if (a.blocked) toast('Sweep did not run: ' + a.blocked);
        else {
          var acted = 0, eligible = 0;
          (a.result && a.result.results || []).forEach(function (r) { acted += r.acted || 0; eligible += r.eligible || 0; });
          toast('Sweep finished: ' + eligible + ' eligible, ' + acted + ' acted on ('
            + (a.result && a.result.action === 'report' ? 'dry run' : (a.result && a.result.action)) + ')');
        }
      } else if (a.action === 'export') {
        toast(a.ok ? ('Health report written to ' + a.files.text) : ('Export failed: ' + (a.error || 'unknown error')));
      } else if (a.action === 'profile') {
        toast(a.ok ? ('Profiler ' + a.message) : ('Profiler did not start: ' + (a.error || 'unknown')));
      }
    }
  });

  document.addEventListener('keydown', function (event) {
    if (root.hidden) return;
    if (event.key === 'Escape') {
      if (!modal.hidden) { modal.hidden = true; return; }
      hide();
    }
  });

  document.getElementById('closeBtn').addEventListener('click', hide);

  tabsEl.addEventListener('click', function (event) {
    var button = event.target.closest('.tab');
    if (!button) return;
    Array.prototype.forEach.call(tabsEl.querySelectorAll('.tab'), function (t) { t.classList.remove('is-active'); });
    button.classList.add('is-active');
    currentTab = button.getAttribute('data-tab');
    render();
    requestRefresh();
  });

  content.addEventListener('click', function (event) {
    var target = event.target;

    var copyBtn = target.closest('[data-copy]');
    if (copyBtn) { copyText(copyBtn.getAttribute('data-copy')); return; }

    var sortTh = target.closest('th.sortable');
    if (sortTh) {
      var key = sortTh.getAttribute('data-sortkey');
      var col = sortTh.getAttribute('data-sortcol');
      var st = sortState[key];
      sortState[key] = (st && st.col === col) ? { col: col, dir: st.dir === 'asc' ? 'desc' : 'asc' } : { col: col, dir: 'desc' };
      render();
      return;
    }

    var expandRow = target.closest('[data-expand]');
    if (expandRow) {
      var id = expandRow.getAttribute('data-expand');
      expanded[id] = !expanded[id];
      render();
      return;
    }

    if (target.id === 'rescan') { post('action', { action: 'rescanEntities' }); toast('Rescanning entities'); return; }
    if (target.id === 'runAudit') { post('action', { action: 'audit' }); toast('Re-running config audit'); return; }
    if (target.id === 'runAnalyze') { post('action', { action: 'analyze' }); toast('Re-running resource analysis'); return; }
    if (target.id === 'runExport') { post('action', { action: 'export' }); toast('Building health report'); return; }

    if (target.id === 'runProfile') {
      confirmAction('Run the server profiler?',
        'While it records, the server does extra work for every resource tick and event, and decoding the result is one blocking step. Do not do this at peak hours the first time.',
        function () { post('action', { action: 'profile' }); toast('Profiler requested'); });
      return;
    }

    if (target.id === 'runSweep') {
      var category = document.getElementById('sweepCategory').value;
      var live = document.getElementById('sweepLive').checked;

      if (!live) {
        post('action', { action: 'sweep', params: { category: category, dryRun: true } });
        toast('Dry run started');
        return;
      }

      var action = (cache.entities && cache.entities.status && cache.entities.status.configuredAction) || 'report';
      confirmAction('Run a LIVE sweep?',
        'This will run with the configured action "' + action + '" on category "' + category
        + '". In monitor mode it is still downgraded to a dry run. This action is written to the log with your identifier.',
        function () {
          post('action', { action: 'sweep', params: { category: category, dryRun: false } });
          toast('Live sweep started');
        });
      return;
    }
  });

  content.addEventListener('change', function (event) {
    if (event.target.id === 'logModule') { logFilters.module = event.target.value; requestRefresh(); }
    if (event.target.id === 'logLevel') { logFilters.level = event.target.value; requestRefresh(); }
  });

  document.getElementById('modalCancel').addEventListener('click', function () { modal.hidden = true; });
})();
