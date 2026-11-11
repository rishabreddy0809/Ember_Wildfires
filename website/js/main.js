// main.js: starts everything. Navigation, the opening counter, scroll animations,
// the Random Forest demo, and the 3D scenes (each in its own file).

import { hasWebGL, reduceMotion } from './lib.js';

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
$('#year').textContent = new Date().getFullYear();
const fmt = (n) => n.toLocaleString('en-US');

/* ---------- Navigation ---------- */
{
  const nav = $('#nav'), toggle = $('.nav-toggle'), links = $('#nav-links');
  const story = $('#story');
  const onScroll = () => nav.classList.toggle('solid', scrollY > story.offsetTop + story.offsetHeight - 60);
  addEventListener('scroll', onScroll, { passive: true }); onScroll();
  toggle.addEventListener('click', () => { const o = links.classList.toggle('open'); toggle.setAttribute('aria-expanded', o); });
  $$('a', links).forEach((a) => a.addEventListener('click', () => { links.classList.remove('open'); toggle.setAttribute('aria-expanded', 'false'); }));
  const map = new Map($$('a:not(.nav-cta)', links).map((a) => [a.getAttribute('href').slice(1), a]));
  const spy = new IntersectionObserver((es) => es.forEach((e) => {
    if (e.isIntersecting && map.has(e.target.id)) { map.forEach((a) => a.classList.remove('active')); map.get(e.target.id).classList.add('active'); }
  }), { rootMargin: '-45% 0px -50% 0px' });
  $$('section[id]').forEach((s) => spy.observe(s));
}

/* ---------- Count-up numbers ---------- */
function countUp(el, to, { decimals = to % 1 ? 2 : 0, suffix = '', ms = 1600 } = {}) {
  if (reduceMotion) { el.textContent = to.toFixed(decimals) + suffix; return; }
  const start = performance.now();
  const step = (t) => {
    const k = Math.min(1, (t - start) / ms), e = 1 - Math.pow(1 - k, 3);
    el.textContent = (to * e).toLocaleString('en-US', { minimumFractionDigits: decimals, maximumFractionDigits: decimals }) + suffix;
    if (k < 1) requestAnimationFrame(step);
    else el.textContent = to.toLocaleString('en-US', { minimumFractionDigits: decimals, maximumFractionDigits: decimals }) + suffix;
  };
  requestAnimationFrame(step);
}

/* ---------- Scroll reveal (+ bars and counters start when visible) ---------- */
{
  const io = new IntersectionObserver((es) => es.forEach((e) => {
    if (!e.isIntersecting) return;
    const el = e.target;
    el.classList.add('in');
    $$('[data-count]', el).forEach((c) => countUp(c, parseFloat(c.dataset.count), { suffix: c.dataset.suffix || '', decimals: c.dataset.count.includes('.') ? (c.dataset.count.split('.')[1].length) : 0 }));
    io.unobserve(el);
  }), { threshold: 0.15 });
  $$('.reveal').forEach((el, i) => { el.style.transitionDelay = `${(i % 3) * 80}ms`; io.observe(el); });
}

/* ---------- Random Forest demo (HTML, no 3D) ---------- */
{
  // Five toy trees with made-up rules. A real Random Forest learns its own questions from training data.
  const TREES = [
    { q: '3+ detections nearby?', vote: (d) => d.neighbors >= 3 },
    { q: 'Fire power over 8 MW?', vote: (d) => d.frp > 8 },
    { q: 'Hotter than 330 K?', vote: (d) => d.bright > 330 },
    { q: 'Confidence high?', vote: (d) => (d.sensor === 'MODIS' ? d.conf >= 60 : d.conf !== 'low') },
    { q: 'Night & over 310 K?', vote: (d) => (d.night && d.bright > 310) || d.neighbors >= 6 },
  ];
  const svg = `<svg viewBox="0 0 34 34" aria-hidden="true"><g stroke="currentColor" stroke-width="1.4" fill="none" opacity=".75"><path d="M17 7 9 17M17 7l8 10M9 17l-4 10M9 17l4 10M25 17l-4 10M25 17l4 10"/></g><g fill="currentColor"><circle cx="17" cy="6" r="3"/><circle cx="9" cy="17" r="2.5"/><circle cx="25" cy="17" r="2.5"/><circle cx="5" cy="28" r="2"/><circle cx="13" cy="28" r="2"/><circle cx="21" cy="28" r="2"/><circle cx="29" cy="28" r="2"/></g></svg>`;
  const card = $('#rf-card'), trees = $('#rf-trees'), verdict = $('#rf-verdict'), tally = $('#rf-tally');
  let det, timers = [];
  const r = (a, b) => a + Math.random() * (b - a);
  const newDet = () => {
    const fire = Math.random() < 0.55, sensor = Math.random() < 0.45 ? 'MODIS' : 'VIIRS';
    return {
      sensor, night: Math.random() < 0.4,
      bright: Math.round(fire ? r(318, 382) : r(298, 340)),
      frp: +(fire ? r(4, 60) : r(0.4, 12)).toFixed(1),
      conf: sensor === 'MODIS' ? Math.round(fire ? r(45, 100) : r(10, 75)) : fire ? (Math.random() < 0.3 ? 'high' : 'nominal') : (Math.random() < 0.6 ? 'low' : 'nominal'),
      neighbors: Math.round(fire ? r(2, 12) : r(0, 3)),
    };
  };
  const render = () => {
    timers.forEach(clearTimeout); timers = [];
    const rows = [['Sensor', det.sensor], ['Brightness', det.bright + ' K'], ['Fire power', det.frp + ' MW'],
      ['Confidence', det.sensor === 'MODIS' ? det.conf + '%' : det.conf], ['Time', det.night ? 'Night' : 'Day'], ['Neighbors', det.neighbors]];
    card.innerHTML = rows.map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('');
    card.querySelector('dd').style.color = det.sensor === 'MODIS' ? 'var(--modis)' : 'var(--viirs)';
    trees.innerHTML = TREES.map((t) => `<div class="tree">${svg}<span class="q">${t.q}</span><span class="v">…</span></div>`).join('');
    verdict.textContent = 'Is this detection a real fire or a false alarm?';
    tally.style.width = '0%'; tally.className = '';
  };
  const run = () => {
    render();
    let yes = 0;
    $$('.tree', trees).forEach((el, i) => timers.push(setTimeout(() => {
      const v = TREES[i].vote(det); if (v) yes++;
      el.classList.add('voted', v ? 'yes' : 'no');
      el.querySelector('.v').textContent = v ? 'Fire' : 'Not fire';
      tally.style.width = `${yes / TREES.length * 100}%`;
      if (i === TREES.length - 1) {
        const fire = yes >= 3;
        tally.className = fire ? 'yes' : 'no';
        verdict.innerHTML = `${yes} of 5 trees voted “fire”, so the forest's answer is: <span class="${fire ? 'yes' : 'no'}">${fire ? 'real fire' : 'false alarm'}</span>.`;
      }
    }, reduceMotion ? 0 : 320 * (i + 1))));
  };
  $('#rf-run').addEventListener('click', run);
  $('#rf-new').addEventListener('click', () => { det = newDet(); render(); });
  det = newDet(); render();
  // The first time the demo scrolls into view, run one vote so it's clear what it does.
  const io = new IntersectionObserver(([e]) => { if (e.isIntersecting) { io.disconnect(); setTimeout(run, 500); } }, { threshold: 0.6 });
  io.observe($('#rf'));
}

/* ---------- The hook ----------
   When the globe is ready, the big number counts up while the fires switch on across the
   planet (js/globe.js runs the same clock), then the rest of the headline fades in. */
const hero = $('.step-hero'), hookNum = $('#hook-num');
const IGNITE_MS = 3400;
let played = false;
function playHook(ignite) {
  if (played) return; played = true;
  const total = +hookNum.dataset.total;
  hero.classList.add('play');
  if (reduceMotion) { hookNum.textContent = fmt(total); hero.classList.add('done'); ignite?.(0); return; }
  hookNum.textContent = '0';
  setTimeout(() => {
    ignite?.(IGNITE_MS);
    const start = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - start) / IGNITE_MS);
      // Matches the shader in globe.js, where the last fire lights at about 89% of the way through.
      hookNum.textContent = fmt(Math.round(total * Math.min(1, k * 1.12)));
      if (k < 1) requestAnimationFrame(step);
      else { hookNum.textContent = fmt(total); hero.classList.add('done'); }
    };
    requestAnimationFrame(step);
  }, 500);
}

/* ---------- 3D scenes ---------- */
let igniteFn = null;
const finishLoading = () => { document.body.classList.remove('loading'); setTimeout(() => playHook(igniteFn), 200); };
setTimeout(finishLoading, 8000);   // never leave the loading screen up forever

if (!hasWebGL()) {
  document.documentElement.classList.add('no-webgl');
  finishLoading();
} else {
  // Globe: load first, since it's at the top of the page
  import('./globe.js').then(({ initGlobe }) => initGlobe({
    canvas: $('#globe'),
    story: $('#story'),
    onReady: async ({ ignite }) => {
      igniteFn = ignite;
      try {
        const meta = await (await fetch('data/meta.json')).json();
        const total = meta.modis + meta.viirs;
        hookNum.dataset.total = total;
        $('#hud-modis').textContent = fmt(meta.modis);
        $('#hud-viirs').textContent = fmt(meta.viirs);
        $('#s1-total').textContent = fmt(total);
        $('#s3-ca').textContent = fmt(meta.california);
        const d = meta.dates.map((s) => new Date(s + 'T00:00:00Z'));
        const opt = { month: 'short', day: 'numeric', timeZone: 'UTC' };
        const range = `${d[0].toLocaleDateString('en-US', opt)}–${d.at(-1).toLocaleDateString('en-US', { day: 'numeric', timeZone: 'UTC' })}, ${d[0].getUTCFullYear()}`;
        $('#s1-dates').textContent = range;
        $('#hud-date').textContent = `NASA FIRMS detections, ${range} (UTC)`;
      } catch { /* the numbers already in the HTML stay */ }
      finishLoading();
    },
    onProgress: (p) => {
      $('#story-progress').style.height = `${p * 100}%`;
      $('#scroll-cue').style.opacity = p > 0.03 ? 0 : 1;
      document.body.classList.toggle('story-start', p < 0.1);
    },
  })).catch((e) => { console.error(e); document.documentElement.classList.add('no-webgl'); finishLoading(); });

  // The other scenes load only when you scroll near them
  const lazy = (el, load) => {
    const io = new IntersectionObserver(([e]) => { if (e.isIntersecting) { io.disconnect(); load(); } }, { rootMargin: '600px' });
    io.observe(el);
  };
  lazy($('#scan-viz'), () => import('./scan.js').then(({ initScan }) => initScan({
    canvas: $('#scan-canvas'), slider: $('#scan-slider'), sizeOut: $('#scan-size'), areaOut: $('#scan-area'), segButtons: $$('#scan-viz .seg button'),
  })));
  lazy($('#app-demo'), () => import('./appmock.js').then(({ initAppMock }) => initAppMock({
    canvas: $('#app-canvas'), regionsEl: $('#app-regions'), modisBox: $('#app-modis'), viirsBox: $('#app-viirs'),
    nModis: $('#app-n-modis'), nViirs: $('#app-n-viirs'), regionName: $('#app-region-name'),
    inspector: $('#app-inspect-body'), hint: $('#app-hint'), colorButtons: $$('#app-demo .seg button'),
  })));
}
