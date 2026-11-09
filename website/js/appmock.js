// appmock.js: an interactive preview of the Ember app, drawn with a plain 2D canvas.
//
// It uses the same REAL detections as the globe (data/fires.bin) and the same land dots (data/land.bin).
// Pick a region, toggle sensors, and click a detection to inspect it.

import { loadFires, loadLand, reduceMotion } from './lib.js';

// [west, south, east, north] in degrees
const REGIONS = [
  { id: 'africa',    name: 'Africa',          box: [-20, -36, 55, 25] },
  { id: 'samerica',  name: 'South America',   box: [-82, -56, -34, 13] },
  { id: 'australia', name: 'Australia',       box: [112, -44, 155, -10] },
  { id: 'seasia',    name: 'Southeast Asia',  box: [90, -11, 155, 30] },
  { id: 'india',     name: 'India',           box: [66, 6, 98, 36] },
  { id: 'uswest',    name: 'Western US',      box: [-125, 31, -102, 49] },
];

const C_MODIS = '#ee9433', C_VIIRS = '#5aa6e8';
const heat = (frp) => {
  const t = Math.min(1, Math.log10(1 + frp) / 2.6);
  if (t < 0.5) return `rgb(${230 + 25 * t * 2 | 0},${30 + 110 * t * 2 | 0},10)`;
  return `rgb(255,${140 + 95 * (t - 0.5) * 2 | 0},${20 + 140 * (t - 0.5) * 2 | 0})`;
};

export async function initAppMock({ canvas, regionsEl, modisBox, viirsBox, nModis, nViirs, regionName, inspector, hint, colorButtons }) {
  const [fires, land] = await Promise.all([loadFires('data/fires.bin'), loadLand('data/land.bin')]);
  const ctx = canvas.getContext('2d');
  let region = REGIONS[0], colorMode = 'sensor', selected = -1, hover = -1;
  let pts = [], landPts = [], reveal = 1, revealStart = 0, raf = 0;
  let W = 0, H = 0, dpr = 1, view = null;

  // ---- Region buttons ----
  regionsEl.innerHTML = REGIONS.map((r, i) => `<button data-i="${i}" class="${i === 0 ? 'on' : ''}">${r.name}</button>`).join('');
  regionsEl.addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (!b) return;
    regionsEl.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
    region = REGIONS[+b.dataset.i]; selected = -1; showInspector();
    build(true);
  });
  colorButtons.forEach((b) => b.addEventListener('click', () => {
    colorButtons.forEach((x) => x.classList.toggle('on', x === b));
    colorMode = b.dataset.color; draw();
  }));
  modisBox.addEventListener('change', () => { selected = -1; showInspector(); draw(); });
  viirsBox.addEventListener('change', () => { selected = -1; showInspector(); draw(); });

  // ---- Projection: equirectangular, with longitude squeezed by cos(latitude) so shapes look right ----
  function makeView() {
    const [w, s, e, n] = region.box;
    const k = Math.cos(((s + n) / 2) * Math.PI / 180);
    const gw = (e - w) * k, gh = n - s, pad = 18 * dpr;
    const scale = Math.min((W - 2 * pad) / gw, (H - 2 * pad) / gh);
    const ox = (W - gw * scale) / 2, oy = (H - gh * scale) / 2;
    return { w, n, k, scale, ox, oy, x: (lon) => ox + (lon - w) * k * scale, y: (lat) => oy + (n - lat) * scale };
  }

  function build(animate) {
    const r = canvas.getBoundingClientRect();
    dpr = Math.min(devicePixelRatio || 1, 2);
    W = canvas.width = Math.max(1, Math.round(r.width * dpr));
    H = canvas.height = Math.max(1, Math.round(r.height * dpr));
    view = makeView();
    const [w, s, e, n] = region.box;
    const m = 2;   // a little margin so land dots reach the edge
    landPts = [];
    for (let i = 0; i < land.n; i++) {
      const la = land.lat[i] / 100, lo = land.lon[i] / 100;
      if (lo < w - m || lo > e + m || la < s - m || la > n + m) continue;
      landPts.push(view.x(lo), view.y(la));
    }
    pts = [];
    let cm = 0, cv = 0;
    for (let i = 0; i < fires.n; i++) {
      const la = fires.lat[i] / 100, lo = fires.lon[i] / 100;
      if (lo < w || lo > e || la < s || la > n) continue;
      const sensor = fires.sensor[i], frp = fires.frp[i] / 10;
      sensor ? cv++ : cm++;
      pts.push({ i, x: view.x(lo), y: view.y(la), lat: la, lon: lo, frp, sensor });
    }
    pts.sort((a, b) => a.frp - b.frp);   // strongest fires drawn last, on top
    nModis.textContent = cm.toLocaleString('en-US');
    nViirs.textContent = cv.toLocaleString('en-US');
    regionName.textContent = region.name;
    if (animate && !reduceMotion) { reveal = 0; revealStart = performance.now(); loop(); }
    else { reveal = 1; draw(); }
  }

  function loop() {
    cancelAnimationFrame(raf);
    const step = (t) => {
      reveal = Math.min(1, (t - revealStart) / 1100);
      draw();
      if (reveal < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
  }

  const visible = (p) => (p.sensor ? viirsBox.checked : modisBox.checked);

  function draw() {
    ctx.clearRect(0, 0, W, H);
    // background grid lines every 10°
    ctx.strokeStyle = 'rgba(120,150,200,0.07)'; ctx.lineWidth = 1;
    const [w, s, e, n] = region.box;
    ctx.beginPath();
    for (let lo = Math.ceil(w / 10) * 10; lo <= e; lo += 10) { const x = view.x(lo); ctx.moveTo(x, view.y(n)); ctx.lineTo(x, view.y(s)); }
    for (let la = Math.ceil(s / 10) * 10; la <= n; la += 10) { const y = view.y(la); ctx.moveTo(view.x(w), y); ctx.lineTo(view.x(e), y); }
    ctx.stroke();

    // land dots
    const lr = Math.max(1.2 * dpr, Math.min(3.2 * dpr, view.scale * 0.22));
    ctx.fillStyle = 'rgba(70,100,150,0.55)';
    for (let i = 0; i < landPts.length; i += 2) { ctx.beginPath(); ctx.arc(landPts[i], landPts[i + 1], lr, 0, 6.283); ctx.fill(); }

    // scanning reveal: a bright line sweeps left → right as a new region loads
    const sweepX = view.ox + reveal * (W - 2 * view.ox);
    const many = pts.length > 20000;
    // additive glow looks great for sparse regions but turns dense ones solid white
    ctx.globalCompositeOperation = pts.length > 3000 ? 'source-over' : 'lighter';
    for (const p of pts) {
      if (!visible(p) || p.x > sweepX) continue;
      const lf = Math.log10(1 + p.frp);
      const r = (many ? 0.9 : 1.6) * dpr * (0.8 + 0.6 * lf);
      ctx.fillStyle = colorMode === 'heat' ? heat(p.frp) : p.sensor ? C_VIIRS : C_MODIS;
      ctx.globalAlpha = many ? 0.55 : 0.85;
      if (p.sensor) {   // VIIRS: diamond
        ctx.beginPath(); ctx.moveTo(p.x, p.y - r); ctx.lineTo(p.x + r, p.y); ctx.lineTo(p.x, p.y + r); ctx.lineTo(p.x - r, p.y); ctx.fill();
      } else {          // MODIS: circle
        ctx.beginPath(); ctx.arc(p.x, p.y, r, 0, 6.283); ctx.fill();
      }
    }
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
    if (reveal < 1) {
      const g = ctx.createLinearGradient(sweepX - 60 * dpr, 0, sweepX, 0);
      g.addColorStop(0, 'rgba(255,140,60,0)'); g.addColorStop(1, 'rgba(255,140,60,0.35)');
      ctx.fillStyle = g; ctx.fillRect(sweepX - 60 * dpr, 0, 60 * dpr, H);
      ctx.fillStyle = 'rgba(255,190,120,0.9)'; ctx.fillRect(sweepX - dpr, 0, 2 * dpr, H);
    }

    // hover + selection rings
    for (const [idx, col, rr] of [[hover, 'rgba(255,255,255,0.6)', 7], [selected, '#fff', 9]]) {
      const p = pts[idx]; if (!p || !visible(p)) continue;
      ctx.strokeStyle = col; ctx.lineWidth = 1.5 * dpr;
      ctx.beginPath(); ctx.arc(p.x, p.y, rr * dpr, 0, 6.283); ctx.stroke();
    }
  }

  // ---- Hit testing: nearest visible detection within a few pixels ----
  function nearest(e) {
    const r = canvas.getBoundingClientRect();
    const mx = (e.clientX - r.left) * dpr, my = (e.clientY - r.top) * dpr;
    let best = -1, bd = (12 * dpr) ** 2;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i]; if (!visible(p)) continue;
      const d = (p.x - mx) ** 2 + (p.y - my) ** 2;
      if (d <= bd) { bd = d; best = i; }   // <= so stronger (later) fires win ties
    }
    return best;
  }
  let pending = null;
  canvas.addEventListener('pointermove', (e) => {
    if (pending) return;
    pending = requestAnimationFrame(() => {
      pending = null;
      const h = nearest(e);
      canvas.style.cursor = h >= 0 ? 'pointer' : 'default';
      if (h !== hover) { hover = h; if (reveal >= 1) draw(); }
    });
  });
  canvas.addEventListener('pointerleave', () => { hover = -1; if (reveal >= 1) draw(); });
  canvas.addEventListener('click', (e) => {
    selected = nearest(e); showInspector(); if (reveal >= 1) draw();
    hint.classList.add('gone');
  });

  function showInspector() {
    const p = pts[selected];
    if (!p) { inspector.innerHTML = '<p class="app-empty">Nothing selected.<br>Click a point on the map.</p>'; return; }
    // count overlapping detections within ~5 km, like the real app's overlap stepping
    let near = 0;
    const km = (a, b) => Math.hypot((a.lon - b.lon) * 111 * Math.cos(a.lat * Math.PI / 180), (a.lat - b.lat) * 111);
    for (const q of pts) if (q !== p && visible(q) && km(p, q) < 5) near++;
    const name = p.sensor ? 'VIIRS' : 'MODIS';
    const rows = [
      ['Sensor', `<span style="color:${p.sensor ? C_VIIRS : C_MODIS}">${name}</span>`],
      ['Satellite', p.sensor ? 'NOAA-20' : 'Terra / Aqua'],
      ['Latitude', p.lat.toFixed(2) + '°'],
      ['Longitude', p.lon.toFixed(2) + '°'],
      ['Fire power', p.frp.toFixed(1) + ' MW'],
      ['Pixel', p.sensor ? '≈375 m' : '≈1 km'],
      ['Within 5 km', `${near} other${near === 1 ? '' : 's'}`],
    ];
    inspector.innerHTML = `<dl class="app-dl">${rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('')}</dl>
      <p class="app-verdict ${near >= 2 ? 'hot' : ''}"><b>Quick neighbor check:</b> ${near >= 2 ? 'clustered with other detections, so likely part of a larger fire.' : 'no close neighbors, so it could be a false alarm or a small fire.'}</p>`;
  }

  let rt;
  new ResizeObserver(() => { clearTimeout(rt); rt = setTimeout(() => build(false), 60); }).observe(canvas);
  // Play the scanning animation the first time the demo scrolls into view
  const io = new IntersectionObserver(([e]) => { if (e.isIntersecting) { io.disconnect(); build(true); } }, { threshold: 0.3 });
  io.observe(canvas);
  build(false);
}
