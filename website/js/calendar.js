// calendar.js: the harmonized fire calendar.
// One square per day, coloured by how many ~1 km cells the harmonized MODIS + VIIRS record
// marks as burning in California. Hover or use the arrow keys for the day's numbers; click
// (or Enter) to draw that day's fire cells on the map, coloured by which sensor saw them.
// Data: data/harmonized.json, made by ml/export_site_data.py.

const $ = (s, el = document) => el.querySelector(s);
const root = $('#cal');
if (root) init();

const RAMP = ['#1a1c22', '#4a2312', '#7a3214', '#b04517', '#e0612a', '#ff9a5c', '#ffd0a8'];
const BINS = [0, 1, 6, 21, 61, 201, 601];               // lower edges for RAMP[1..]
const SRC_COLORS = ['#d95926', '#199e70', '#3987e5'];   // MODIS only, both, VIIRS only
const SRC_NAMES = ['MODIS only', 'Both sensors', 'VIIRS only'];
const CELL = 12, GAP = 2, LEFT = 26, TOP = 18;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const fmt = (n) => n.toLocaleString('en-US');

function binColor(n) {
  let k = 0;
  for (let i = 1; i < BINS.length; i++) if (n >= BINS[i]) k = i;
  return RAMP[k];
}

function inGap(gaps, iso) {
  return (gaps || []).some((g) => { const [a, b] = g.split(' to '); return iso >= a && iso <= b; });
}

async function init() {
  let data;
  try {
    data = await (await fetch('data/harmonized.json')).json();
  } catch {
    $('#cal-status').textContent = 'Could not load the harmonized record.';
    return;
  }
  const years = Object.keys(data.years).sort();
  let year = years[years.length - 1], selected = null;

  const seg = $('#cal-years');
  years.forEach((y) => {
    const b = document.createElement('button');
    b.textContent = y; b.dataset.year = y;
    b.addEventListener('click', () => { year = y; selected = null; draw(); });
    seg.appendChild(b);
  });

  const svg = $('#cal-grid'), tip = $('#cal-tip'), canvas = $('#cal-map');

  function dayInfo(iso) {
    const d = data.years[year].days[iso];
    const n = d ? d.n : [0, 0, 0];
    return { iso, d, n, total: n[0] + n[1] + n[2], gaps: data.years[year].gaps };
  }

  function describe(info) {
    const date = new Date(info.iso + 'T12:00:00').toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
    const notes = [];
    if (inGap(info.gaps.VIIRS, info.iso)) notes.push('Suomi NPP VIIRS: no data');
    if (inGap(info.gaps.MODIS, info.iso)) notes.push('MODIS: no detections');
    let html = `<b>${date}</b>`;
    if (!info.total) html += '<span>No fire cells</span>';
    else {
      html += `<span class="cal-tip-total">${fmt(info.total)} fire cells</span>`;
      info.n.forEach((v, i) => { html += `<span><i style="background:${SRC_COLORS[i]}"></i>${SRC_NAMES[i]} <em>${fmt(v)}</em></span>`; });
      if (info.d.frp) html += `<span>Peak fire power <em>${fmt(Math.round(info.d.frp))} MW</em></span>`;
    }
    notes.forEach((t) => { html += `<span class="cal-tip-note">${t}</span>`; });
    return html;
  }

  function drawMap(info) {
    const ctx = canvas.getContext('2d');
    const dpr = devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
    canvas.width = w * dpr; canvas.height = h * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const lon0 = -124.6, lon1 = -113.9, lat0 = 32.4, lat1 = 42.1;
    const kx = Math.cos((37 * Math.PI) / 180);
    const s = Math.min((w - 16) / ((lon1 - lon0) * kx), (h - 16) / (lat1 - lat0));
    const ox = (w - (lon1 - lon0) * kx * s) / 2, oy = (h - (lat1 - lat0) * s) / 2;
    const X = (lon) => ox + (lon - lon0) * kx * s, Y = (lat) => oy + (lat1 - lat) * s;
    ctx.strokeStyle = 'rgba(241,237,230,0.35)'; ctx.lineWidth = 1; ctx.fillStyle = 'rgba(255,255,255,0.025)';
    data.outline.forEach((ring) => {
      ctx.beginPath(); ring.forEach(([x, y], i) => (i ? ctx.lineTo(X(x), Y(y)) : ctx.moveTo(X(x), Y(y))));
      ctx.closePath(); ctx.fill(); ctx.stroke();
    });
    const c = info.d ? info.d.c : [], cd = data.cell_deg, px = Math.max(3, cd * kx * s);
    for (let k = 0; k < c.length; k += 3) {
      const lat = (c[k] + 0.5) * cd, lon = (c[k + 1] + 0.5) * cd;
      ctx.fillStyle = SRC_COLORS[c[k + 2]];
      ctx.fillRect(X(lon) - px / 2, Y(lat) - px / 2, px, px);
    }
    const date = new Date(info.iso + 'T12:00:00').toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' });
    $('#cal-map-title').textContent = info.total ? `${date}: ${fmt(info.total)} fire cells` : `${date}: no fire cells`;
    canvas.setAttribute('aria-label', `Map of California fire cells on ${date}: ` +
      info.n.map((v, i) => `${v} ${SRC_NAMES[i]}`).join(', '));
  }

  function draw() {
    seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.year === year));
    const first = new Date(Date.UTC(+year, 0, 1)), offset = first.getUTCDay();
    const ndays = (Date.UTC(+year + 1, 0, 1) - first) / 864e5;
    const weeks = Math.ceil((ndays + offset) / 7);
    const W = LEFT + weeks * (CELL + GAP), H = TOP + 7 * (CELL + GAP);
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('width', W); svg.setAttribute('height', H);
    const NS = 'http://www.w3.org/2000/svg';
    svg.replaceChildren();
    ['Mon', 'Wed', 'Fri'].forEach((t, i) => {
      const e = document.createElementNS(NS, 'text'); e.textContent = t;
      e.setAttribute('x', 0); e.setAttribute('y', TOP + (2 * i + 1) * (CELL + GAP) + CELL - 3); svg.appendChild(e);
    });
    let busiest = null, total = 0, active = 0;
    const cells = [];
    for (let k = 0; k < ndays; k++) {
      const d = new Date(first.getTime() + k * 864e5), iso = d.toISOString().slice(0, 10);
      const col = Math.floor((k + offset) / 7), row = (k + offset) % 7;
      if (d.getUTCDate() === 1) {
        const t = document.createElementNS(NS, 'text'); t.textContent = MONTHS[d.getUTCMonth()];
        t.setAttribute('x', LEFT + col * (CELL + GAP)); t.setAttribute('y', 11); svg.appendChild(t);
      }
      const info = dayInfo(iso);
      total += info.total; if (info.total) active++;
      if (!busiest || info.total > busiest.total) busiest = info;
      const r = document.createElementNS(NS, 'rect');
      r.setAttribute('x', LEFT + col * (CELL + GAP)); r.setAttribute('y', TOP + row * (CELL + GAP));
      r.setAttribute('width', CELL); r.setAttribute('height', CELL); r.setAttribute('rx', 3);
      r.setAttribute('fill', binColor(info.total));
      if (inGap(info.gaps.VIIRS, iso)) r.classList.add('gap');
      r.dataset.k = k;
      svg.appendChild(r); cells.push({ r, info });
    }
    $('#cal-summary').textContent = `${year}: ${fmt(total)} fire cell-days on ${active} days. Busiest: ` +
      new Date(busiest.iso + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ` (${fmt(busiest.total)} cells).`;
    const y = data.years[year];
    $('#cal-agree').innerHTML = `MODIS–VIIRS match rate <b>${Math.round(y.match_before * 100)}% → ${Math.round(y.match_after * 100)}%</b> · fire-map overlap <b>${Math.round(y.overlap_before * 100)}% → ${Math.round(y.overlap_after * 100)}%</b> after harmonization`;

    let sel = selected ? cells.findIndex((c) => c.info.iso === selected) : cells.indexOf(cells.find((c) => c.info === busiest));
    const choose = (i) => {
      sel = Math.max(0, Math.min(cells.length - 1, i));
      cells.forEach((c, j) => c.r.classList.toggle('sel', j === sel));
      selected = cells[sel].info.iso;
      drawMap(cells[sel].info);
      $('#cal-live').innerHTML = describe(cells[sel].info);
    };
    const show = (i, ev) => {
      tip.innerHTML = describe(cells[i].info); tip.hidden = false;
      const box = root.getBoundingClientRect(), rb = cells[i].r.getBoundingClientRect();
      let x = rb.left - box.left + rb.width / 2, yv = rb.top - box.top;
      tip.style.left = `${Math.min(Math.max(x, 110), box.width - 110)}px`; tip.style.top = `${yv}px`;
    };
    svg.onmousemove = (e) => { const k = e.target.dataset && e.target.dataset.k; if (k != null) show(+k, e); };
    svg.onmouseleave = () => { tip.hidden = true; };
    svg.onclick = (e) => { const k = e.target.dataset && e.target.dataset.k; if (k != null) choose(+k); };
    svg.onkeydown = (e) => {
      const step = { ArrowLeft: -7, ArrowRight: 7, ArrowUp: -1, ArrowDown: 1 }[e.key];
      if (step) { e.preventDefault(); choose(sel + step); show(sel); }
      if (e.key === 'Escape') tip.hidden = true;
    };
    svg.onblur = () => { tip.hidden = true; };
    choose(sel);
  }

  // Legend
  const leg = $('#cal-legend');
  leg.innerHTML = '<span>Fire cells per day</span>' + RAMP.map((c, i) =>
    `<i style="background:${c}" title="${i === 0 ? 'none' : BINS[i] + (i < RAMP.length - 1 ? '–' + (BINS[i + 1] - 1) : '+')}"></i>`).join('') +
    `<span class="cal-leg-scale">0 · 1 · 6 · 21 · 61 · 201 · 601+</span><span class="cal-leg-gap"><i></i>Suomi NPP VIIRS outage</span>`;
  $('#cal-map-legend').innerHTML = SRC_NAMES.map((n, i) => `<span><i style="background:${SRC_COLORS[i]}"></i>${n}</span>`).join('');
  $('#cal-status').remove();
  addEventListener('resize', () => { if (selected) drawMap(dayInfo(selected)); });
  draw();
}
