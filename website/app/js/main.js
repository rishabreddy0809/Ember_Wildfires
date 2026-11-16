// main.js: the Ember web app. The same views as the Mac app's Globe tab, fed by /api/fires.

import { createGlobe, HOME_DIST } from './globe.js';
import { loadFires, summarize, shows, detection, THRESHOLD, grouped, compact, share, power,
         span, dayCount, coordinate, ago, utcDay, utcTime } from './data.js';

const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const state = {
  data: null, mode: 'both', region: null, fire: -1, query: '',
  sum: null,           // totals for the current mode
};

const CAPTIONS = {
  both: 'Every detection from both sensors, exactly as FIRMS reported it.',
  modis: 'MODIS only: Terra and Aqua, 1 km pixels.',
  viirs: 'VIIRS only: 375 m pixels, about seven times finer than MODIS.',
  wildfire: `Only what Ember's model scores at ${Math.round(THRESHOLD * 100)}% or more as a real wildfire, not a farm burn, industrial heat or a false alarm. Trained on California, so treat it as a guide elsewhere.`,
};
const ACTIVITY = {
  intense: { label: 'Intense', icon: '<svg viewBox="0 0 16 16"><path d="M8.2 1.6c.3 2-1 3-1.9 4.1C5.3 6.9 4.5 8 4.5 9.7A3.6 3.6 0 0 0 8 13.4a3.6 3.6 0 0 0 3.5-3.7c0-1.3-.6-2.3-1.2-3 .1 1-.3 1.8-1 2.1.4-2.6-.5-5.4-1.1-7.2z"/></svg>' },
  active: { label: 'Active', icon: '<svg viewBox="0 0 16 16"><rect x="7" y="3.2" width="2" height="6.4" rx="1"/><circle cx="8" cy="12.2" r="1.25"/></svg>' },
  quiet: { label: 'Quiet', icon: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="2.6"/></svg>' },
};

// ---------------------------------------------------------------- globe

const stage = $('#stage');
const tip = $('#tip');
const globe = createGlobe($('#globe'), {
  onHover(i, x, y) {
    if (i < 0 || i === state.fire) { tip.hidden = true; return; }
    const d = detection(state.data, i);
    const r = stage.getBoundingClientRect();
    tip.innerHTML = `<i class="dot ${d.viirs ? 'viirs' : 'modis'}"></i><b>${d.sensor}</b> ${d.frp != null ? power(d.frp) : ''}`
      + (d.score != null ? ` · <span class="${d.score >= THRESHOLD ? 'wild' : ''}">${Math.round(d.score * 100)}% wildfire</span>` : '')
      + `<em>Click for details</em>`;
    tip.hidden = false;
    tip.style.transform = `translate(${Math.round(x - r.left + 16)}px, ${Math.round(y - r.top - 14)}px)`;
  },
  onPick(i) {
    tip.hidden = true;
    if (i >= 0) showFire(i);
    else if (state.fire >= 0) { state.fire = -1; renderInspector(); }
  },
  onMove: placeLabels,
});

// ---------------------------------------------------------------- data

async function load() {
  setStatus('loading', 'Contacting NASA FIRMS…');
  $('#loader').hidden = false;
  $('#loader-error').hidden = true;
  $('#loader-text').textContent = 'Downloading the last 48 hours of fire detections from NASA FIRMS and scoring each one…';
  try {
    const t0 = performance.now();
    const f = await loadFires();
    const first = !state.data;
    state.data = f;
    globe.setData(f);
    apply();
    if (first && state.sum.regions[0]) globe.flyTo(state.sum.regions[0].lat, state.sum.regions[0].lon);
    $('#loader').hidden = true;
    const h = f.header;
    const missing = ['modis', 'viirs'].filter((s) => h.sources[s]?.error);
    setStatus(missing.length ? 'warn' : 'ok',
      missing.length ? `${missing.map((s) => s.toUpperCase()).join(' and ')} unavailable right now` : `Live · updated ${ago(Date.parse(h.fetchedAt))}`);
    console.info(`Ember: ${f.n} detections in ${Math.round(performance.now() - t0)} ms`, h);
  } catch (e) {
    console.error(e);
    $('#loader-error').hidden = false;
    $('#loader-error-text').textContent = e.message;
    $('#loader-text').textContent = "Couldn't download the fire data.";
    setStatus('error', 'Offline');
  }
}

function setStatus(kind, text) {
  const s = $('#status');
  s.dataset.kind = kind;
  $('#status-text').textContent = text;
  $('#refresh').disabled = kind === 'loading';
}

/** Recomputes everything for the current display mode. */
function apply() {
  const f = state.data;
  if (!f) return;
  state.sum = summarize(f, state.mode, dayCount(f.header));
  globe.setShown((i) => shows(f, i, state.mode));
  globe.setBoost(state.mode === 'wildfire' ? 1.7 : 1);   // few fires: draw them bigger
  if (state.fire >= 0 && !shows(f, state.fire, state.mode)) { state.fire = -1; globe.select(-1); }
  if (state.region && !state.sum.regions.some((r) => r.id === state.region)) state.region = null;
  renderAll();
}

// ---------------------------------------------------------------- rendering

function current() {
  return state.region == null ? state.sum.world : state.sum.regions.find((r) => r.id === state.region);
}

function renderAll() {
  renderSide();
  renderCard();
  renderInspector();
  renderLabels();
}

function renderSide() {
  const f = state.data, h = f.header, w = state.sum.world;
  const sats = h.satellites.map((s) => ({ T: 'Terra', A: 'Aqua', N20: 'NOAA-20', N: 'Suomi NPP', N21: 'NOAA-21' }[s] || s));
  $('#scope-name').textContent = state.region == null ? 'Whole world' : current().name;
  $('#scope-sub').textContent = `${span(h)} · ${sats.join(', ')}`;
  $('#scope').classList.toggle('region', state.region != null);
  $('#shown').textContent = `${grouped(w.count)} shown`;
  for (const b of document.querySelectorAll('#modes button')) b.setAttribute('aria-pressed', String(b.dataset.mode === state.mode));
  $('#caption').textContent = CAPTIONS[state.mode];

  const q = state.query.trim().toLowerCase();
  const list = state.sum.regions.filter((r) => !q || r.name.toLowerCase().includes(q) || r.continent.toLowerCase().includes(q));
  $('#region-count').textContent = `${list.length} of ${state.sum.regions.length}`;
  $('#regions').innerHTML = list.map((r) => `
    <li><button data-region="${r.id}" aria-pressed="${r.id === state.region}">
      <span class="badge ${r.activity}" title="${ACTIVITY[r.activity].label}">${ACTIVITY[r.activity].icon}</span>
      <span class="rname"><b>${esc(r.name)}</b><small>${esc(r.continent)} · peak ${Math.round(r.peak)} MW</small></span>
      <span class="rcount">${grouped(r.count)}</span>
    </button></li>`).join('') || '<li class="empty">No regions match.</li>';
}

function renderCard() {
  const s = current(), w = state.sum.world;
  const where = state.region == null ? 'worldwide' : `in ${s.name}`;
  $('#card-count').textContent = grouped(s.count);
  $('#card-what').innerHTML = `${state.mode === 'wildfire' ? 'likely wildfire detections' : 'fire detections'},<br>${esc(where)}, ${esc(span(state.data.header))}`;
  $('#card-chips').innerHTML = `
    <span><i class="dot modis"></i>${grouped(s.modis)} MODIS</span>
    <span><i class="dot viirs diamond"></i>${grouped(s.viirs)} VIIRS</span>
    <span><i class="dot wild"></i>${share(s.wildfire, s.scored)} likely wildfire</span>`;
  void w;
}

function renderInspector() {
  const el = $('#inspector');
  if (state.fire >= 0) { el.innerHTML = fireView(state.fire); el.scrollTop = 0; return; }
  const s = current(), isWorld = state.region == null, f = state.data;
  const days = dayCount(f.header);
  const finer = s.viirs >= s.modis ? 'VIIRS' : 'MODIS';
  const lead = isWorld ? `${grouped(s.count)} detections in ${days === 1 ? 'one day' : `${days} days`}.`
    : `${ACTIVITY[s.activity].label}: ${grouped(s.count)} detections in ${days === 1 ? 'one day' : `${days} days`}.`;
  const rows = [
    ['MODIS (1 km)', grouped(s.modis)],
    ['VIIRS (375 m)', grouped(s.viirs)],
    ['Typical fire power', s.median != null ? power(s.median) : '—'],
    ['All fire power', power(s.total)],
    ['High confidence', share(s.high, s.count)],
    ['Seen at night', share(s.night, s.count)],
    ['Likely wildfire', `${grouped(s.wildfire)} (${share(s.wildfire, s.scored)})`],
  ];
  el.innerHTML = `
    <h1 class="serif">${esc(s.name)}</h1>
    <p class="sub">${isWorld ? `${esc(span(f.header))}. ${state.sum.regions.length} regions with fire.` : `${esc(s.continent)} · ${esc(span(f.header))}`}</p>
    <p class="lead"><b>${lead}</b> ${share(Math.max(s.viirs, s.modis), s.count)} came from ${finer}, and ${share(s.night, s.count)} were seen at night.</p>
    <div class="big3">
      <div><h4>Detections</h4><b class="serif">${compact(s.count)}</b><small>Satellite pixels flagged as burning.</small></div>
      <div><h4>Strongest</h4><b class="serif">${compact(s.peak)}</b><small>Megawatts from the hottest pixel.</small></div>
      <div><h4>Wildfire</h4><b class="serif">${share(s.wildfire, s.scored)}</b><small>Share the model calls wildfire.</small></div>
    </div>
    <h3>In numbers</h3>
    <dl class="rows">${rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('')}</dl>
    ${isWorld ? `<h3>Busiest regions</h3><ul class="mini">${state.sum.regions.slice(0, 5).map((r) => `
      <li><button data-region="${r.id}"><span class="badge ${r.activity}">${ACTIVITY[r.activity].icon}</span><span>${esc(r.name)}</span><b>${grouped(r.count)}</b></button></li>`).join('')}</ul>` : ''}
    <h3>Strongest fires</h3>
    <ul class="mini">${s.top.map((i) => { const d = detection(f, i); return `
      <li><button data-fire="${i}"><i class="dot ${d.viirs ? 'viirs diamond' : 'modis'}"></i>
        <span>${d.sensor} · ${d.region.name}<small>${d.time ? `${utcDay(d.time)}, ${utcTime(d.time)}` : ''}</small></span>
        <b>${d.frp != null ? power(d.frp) : '—'}</b></button></li>`; }).join('')}</ul>
    <div class="actions">
      ${isWorld ? '<button class="btn primary" data-act="first">First region</button>' : '<button class="btn primary" data-act="next">Next region</button><button class="btn" data-act="world">Back to everything</button>'}
      <button class="btn" data-act="csv">Download CSV</button>
    </div>
    <p class="fine">Regions are rough boxes for grouping detections, not borders. "Intense" means 2,500 or more detections a day, "Active" 250 or more.</p>`;
}

function fireView(i) {
  const d = detection(state.data, i);
  const res = d.viirs ? '375 m' : '1 km';
  const when = d.time ? `at ${utcTime(d.time)} on ${utcDay(d.time)}` : '';
  const ago_ = d.time ? ` That was ${ago(d.time.getTime())}.` : '';
  const p = d.score;
  const rows = [
    ['Fire power', d.frp != null ? `${d.frp.toFixed(1)} MW` : '—'],
    [d.viirs ? 'Brightness, I-4 (bright_ti4)' : 'Brightness, ch. 21/22', d.bright != null ? `${d.bright.toFixed(1)} K` : '—'],
    [d.viirs ? 'Brightness, I-5 (bright_ti5)' : 'Brightness, ch. 31', d.bright2 != null ? `${d.bright2.toFixed(1)} K` : '—'],
    ['Confidence', d.confidence],
    ['Day or night', d.dayNight],
    ['Pixel size', d.scan != null && d.track != null ? `${d.scan.toFixed(2)} × ${d.track.toFixed(2)} km` : '—'],
    ['Satellite', d.satellite],
    ['Time (UTC)', d.time ? d.time.toISOString().slice(0, 16).replace('T', ' ') : '—'],
  ];
  const firms = `https://firms.modaps.eosdis.nasa.gov/map/#d:24hrs;@${d.lon.toFixed(3)},${d.lat.toFixed(3)},11.0z`;
  return `
    <p class="kicker"><i class="dot ${d.viirs ? 'viirs diamond' : 'modis'}"></i>${d.viirs ? 'VIIRS · 375 m pixel' : 'MODIS · 1 km pixel'}</p>
    <h1 class="serif">${d.sensor}<br>detection</h1>
    <p class="sub">${esc(d.region.name)}. ${coordinate(d.lat, d.lon, 4)}</p>
    <p class="lead"><b>Seen by ${esc(d.satellite)} ${when}.</b>${ago_} One ${res} pixel flagged as burning; the fire is somewhere inside it.</p>
    ${p != null ? `
    <div class="prob ${p >= THRESHOLD ? 'wild' : ''}">
      <div class="bar"><span style="width:${Math.round(p * 100)}%"></span><i style="left:${THRESHOLD * 100}%"></i></div>
      <p>Wildfire probability: <b>${Math.round(p * 100)}%</b>, ${p >= THRESHOLD ? 'above' : 'below'} the ${Math.round(THRESHOLD * 100)}% cut.</p>
      <small>Not wildfire usually means a farm or prescribed burn, an industrial heat source, or a false alarm. The model was trained on California, so treat it as a guide elsewhere.</small>
    </div>` : ''}
    <h3>As reported</h3>
    <dl class="rows">${rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>
    <div class="actions">
      <a class="btn primary" href="${firms}" target="_blank" rel="noopener">Open in NASA FIRMS</a>
      <button class="btn" data-act="unfire">Back to ${esc(state.region == null ? 'everything' : current().name)}</button>
    </div>`;
}

// Region names floating over the globe, for the busiest few.
let labels = [];
function renderLabels() {
  const layer = $('#labels');
  const top = state.region == null ? state.sum.regions.slice(0, 7) : state.sum.regions.filter((r) => r.id === state.region);
  layer.innerHTML = top.map((r) => `<button class="label ${r.activity}" data-region="${r.id}"><i></i>${esc(r.name)} <span>${compact(r.count)}</span></button>`).join('');
  labels = top.map((r, k) => ({ r, el: layer.children[k] }));
  placeLabels();
}
function placeLabels() {
  const placed = [];
  for (const { r, el } of labels) {
    const p = globe.screenOf(r.lat, r.lon);
    // Busiest first; a label that would sit on top of a busier one is hidden.
    const w = el.offsetWidth || 120;
    const box = { x0: p.x - 9, x1: p.x - 9 + w, y0: p.y - 12, y1: p.y + 12 };
    const clash = placed.some((b) => box.x0 < b.x1 + 4 && box.x1 > b.x0 - 4 && box.y0 < b.y1 && box.y1 > b.y0);
    const show = p.facing > 0.25 && !clash;
    if (show) placed.push(box);
    el.style.opacity = show ? Math.min(1, (p.facing - 0.25) * 5) : 0;
    el.style.pointerEvents = show ? '' : 'none';
    el.style.transform = `translate(${Math.round(p.x)}px, ${Math.round(p.y)}px)`;
  }
}

// ---------------------------------------------------------------- actions

function selectRegion(id, { fly = true } = {}) {
  state.region = id;
  state.fire = -1; globe.select(-1);
  const s = current();
  if (fly) {
    // The whole world: face the busiest region (the middle of every fire on Earth is meaningless).
    if (id == null) { const b = state.sum.regions[0]; globe.flyTo(b ? b.lat : 10, b ? b.lon : 15, HOME_DIST); }
    else globe.flyTo(s.lat, s.lon, Math.min(3, 1.42 + Math.max(0, s.lat1 - s.lat0) / 32));
  }
  renderAll();
}

function showFire(i) {
  state.fire = i;
  globe.select(i);
  renderInspector();
  $('#inspector-wrap').classList.add('open');
}

function stepRegion(by) {
  const list = state.sum.regions;
  if (!list.length) return;
  const k = list.findIndex((r) => r.id === state.region);
  selectRegion(list[(k + by + list.length) % list.length].id);
}

function downloadCSV() {
  const f = state.data;
  const cols = ['sensor', 'latitude', 'longitude', 'frp_mw', 'brightness_k', 'brightness2_k', 'scan_km', 'track_km', 'acq_utc', 'satellite', 'confidence', 'daynight', 'p_wildfire', 'region'];
  const lines = [cols.join(',')];
  for (let i = 0; i < f.n; i++) {
    if (!shows(f, i, state.mode) || (state.region != null && f.region[i] !== state.region)) continue;
    const d = detection(f, i);
    lines.push([d.sensor, d.lat.toFixed(5), d.lon.toFixed(5), d.frp ?? '', d.bright ?? '', d.bright2 ?? '', d.scan ?? '', d.track ?? '',
      d.time ? d.time.toISOString().slice(0, 16) + 'Z' : '', d.satellite, d.confidence, d.dayNight, d.score ?? '', `"${d.region.name}"`].join(','));
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([lines.join('\n')], { type: 'text/csv' }));
  a.download = `ember-${state.region == null ? 'world' : current().name.toLowerCase().replace(/\W+/g, '-')}-${state.mode}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-region],[data-fire],[data-act],[data-mode]');
  if (!t) return;
  if (t.dataset.mode) { state.mode = t.dataset.mode; apply(); return; }
  if (t.dataset.region !== undefined) {
    const id = Number(t.dataset.region);
    selectRegion(state.region === id && t.closest('#regions') ? null : id);
    return;
  }
  if (t.dataset.fire !== undefined) {
    const i = Number(t.dataset.fire);
    const d = detection(state.data, i);
    globe.flyTo(d.lat, d.lon, 1.3);
    showFire(i);
    return;
  }
  switch (t.dataset.act) {
    case 'first': stepRegion(1); break;
    case 'next': stepRegion(1); break;
    case 'world': selectRegion(null); break;
    case 'csv': downloadCSV(); break;
    case 'unfire': state.fire = -1; globe.select(-1); renderInspector(); break;
    case 'retry': case 'refresh': load(); break;
    case 'zoom-in': globe.zoom(0.7); break;
    case 'zoom-out': globe.zoom(1 / 0.7); break;
    case 'clouds': case 'spin': {
      const on = t.getAttribute('aria-pressed') !== 'true';
      t.setAttribute('aria-pressed', String(on));
      if (t.dataset.act === 'clouds') globe.setClouds(on); else globe.setSpin(on);
      break;
    }
    case 'panel': $('#inspector-wrap').classList.toggle('open'); break;
  }
});
$('#scope').addEventListener('click', () => { if (state.region != null) selectRegion(null); });
$('#search').addEventListener('input', (e) => { state.query = e.target.value; if (state.sum) renderSide(); });
addEventListener('keydown', (e) => {
  if (e.target.closest('input')) return;
  if (e.key === 'Escape') { if (state.fire >= 0) { state.fire = -1; globe.select(-1); renderInspector(); } else if (state.region != null) selectRegion(null); }
  if (e.key === ']' || e.key === 'ArrowDown' && e.altKey) stepRegion(1);
  if (e.key === '[') stepRegion(-1);
});
// Keep "updated N min ago" current.
setInterval(() => { const h = state.data?.header; if (h && $('#status').dataset.kind === 'ok') $('#status-text').textContent = `Live · updated ${ago(Date.parse(h.fetchedAt))}`; }, 60000);

window.ember = { globe, state };   // handy from the browser console
load();
