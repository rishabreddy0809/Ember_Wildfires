// data.js: downloads the live fire data (/api/fires) and works out the regions and totals.
// The same rules as the Mac app: Store/FireStore.swift and Models/WorldRegion.swift.

export const THRESHOLD = 0.6;   // the model's cut, from ml/outputs/swift_threshold.txt

/** Downloads and reads /api/fires (format described in api/fires.js). */
export async function loadFires(url = '/api/fires') {
  const res = await fetch(url);
  if (!res.ok) {
    let msg = `The server answered ${res.status}.`;
    try { msg = (await res.json()).error || msg; } catch { /* not JSON */ }
    throw new Error(msg);
  }
  let bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) {   // still gzipped (some proxies pass it through)
    const s = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
    bytes = new Uint8Array(await new Response(s).arrayBuffer());
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (String.fromCharCode(...bytes.subarray(0, 4)) !== 'EMBR') throw new Error('The fire data came back in an unexpected format.');
  const len = view.getUint32(4, true);
  const header = JSON.parse(new TextDecoder().decode(bytes.subarray(8, 8 + len)));
  let at = 8 + len; at += (4 - (at % 4)) % 4;
  const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const raw = {};
  for (const [name, type] of header.columns) {
    const T = globalThis[type];
    raw[name] = new T(buf, at, header.n);
    at += T.BYTES_PER_ELEMENT * header.n;
  }
  const n = header.n;
  // Undo the running differences on positions.
  const lat = new Float32Array(n), lon = new Float32Array(n);
  let la = 0, lo = 0;
  for (let i = 0; i < n; i++) { la += raw.lat[i]; lo += raw.lon[i]; lat[i] = la / 1e5; lon[i] = lo / 1e5; }
  const region = new Uint8Array(n);
  for (let i = 0; i < n; i++) region[i] = regionIndex(lat[i], lon[i]);
  return { header, n, lat, lon, region, ...pick(raw, ['frp', 'bright', 'bright2', 'scan', 'track', 'minute', 'score', 'sensor', 'conf', 'daynight', 'sat']) };
}
const pick = (o, keys) => Object.fromEntries(keys.map((k) => [k, o[k]]));

// ---------------------------------------------------------------- one detection

/** Everything about detection i, in readable form. */
export function detection(f, i) {
  const viirs = f.sensor[i] === 1;
  const sat = f.header.satellites[f.sat[i]] ?? '';
  const m = f.minute[i];
  const time = m === 65535 ? null : new Date((f.header.minute0 + m) * 60000);
  const c = f.conf[i];
  const s = f.score[i];
  return {
    i, viirs, sensor: viirs ? 'VIIRS' : 'MODIS',
    lat: f.lat[i], lon: f.lon[i],
    frp: Number.isNaN(f.frp[i]) ? null : f.frp[i],
    bright: f.bright[i] ? f.bright[i] / 10 : null,
    bright2: f.bright2[i] ? f.bright2[i] / 10 : null,
    scan: f.scan[i] ? f.scan[i] / 50 : null,
    track: f.track[i] ? f.track[i] / 50 : null,
    time,
    satellite: SATELLITES[sat.toUpperCase()] ?? sat,
    confidence: c === 255 ? 'Unknown' : c > 100 ? ['Low', 'Nominal', 'High'][c - 101] : `${c}%`,
    highConfidence: c === 103 || (c <= 100 && c >= 80),
    night: f.daynight[i] === 1,
    dayNight: ['Day', 'Night', 'Unknown'][f.daynight[i]],
    score: s === 65535 ? null : s / 10000,
    region: REGIONS[f.region[i]],
  };
}
const SATELLITES = { T: 'Terra', A: 'Aqua', N: 'Suomi NPP', N20: 'NOAA-20', 1: 'NOAA-20', N21: 'NOAA-21' };

// ---------------------------------------------------------------- regions

// Rough boxes (lon0, lat0, lon1, lat1), checked in order; the first that holds a fire wins.
const BOXES = [
  ['Alaska and Yukon', 'North America', -170, 54, -130, 72],
  ['California', 'North America', -124.6, 32.4, -114.1, 42.0],
  ['Pacific Northwest', 'North America', -125, 42, -110, 49.2],
  ['Western Canada', 'North America', -130, 49, -95, 70],
  ['Southwest and Rockies', 'North America', -120, 31.3, -102, 42],
  ['Central United States', 'North America', -110, 29.5, -93, 49],
  ['Great Lakes and Northeast', 'North America', -93, 36.5, -66, 47.5],
  ['Eastern Canada', 'North America', -95, 45, -52, 63],
  ['US Southeast', 'North America', -93, 24.5, -75, 36.5],
  ['Central America', 'North America', -92.3, 7, -77, 18.3],
  ['Mexico', 'North America', -118, 14.5, -86.5, 32.4],
  ['Caribbean', 'North America', -85, 9.5, -59, 27],
  ['Northern South America', 'South America', -79.5, 1, -50, 13],
  ['Andes and Pacific Coast', 'South America', -82, -30, -70, -13],
  ['Amazon Basin', 'South America', -79.5, -13, -50, 1],
  ['Eastern Brazil', 'South America', -50, -24, -34, 1],
  ['Chaco and Pantanal', 'South America', -70, -30, -50, -13],
  ['Southern Cone', 'South America', -76, -56, -48, -24],
  ['British Isles', 'Europe', -11, 49.8, 2, 61],
  ['Iberia', 'Europe', -10, 36, 3.3, 44],
  ['North Africa and Sahara', 'Africa', -18, 16, 11.8, 37.4],
  ['Southern Europe', 'Europe', 6, 34.8, 29, 46.5],
  ['Western Europe', 'Europe', -6, 42, 16, 55.5],
  ['Northern Europe', 'Europe', -25, 54.5, 31, 72],
  ['Madagascar', 'Africa', 42.5, -26.5, 51, -11.5],
  ['West Africa', 'Africa', -18, 3.5, 15, 16],
  ['Central Africa', 'Africa', 8, -6, 32, 13],
  ['Middle East', 'Asia', 42.6, 12.5, 60, 32],
  ['East Africa', 'Africa', 32, -12, 52, 16],
  ['North Africa and Sahara', 'Africa', -18, 13, 37, 34.8],
  ['South-Central Africa', 'Africa', 10, -19, 42, -6],
  ['Southern Africa', 'Africa', 10, -36, 42, -19],
  ['Middle East', 'Asia', 26, 12, 48.5, 44],
  ['Middle East', 'Asia', 48.5, 12, 63, 38],
  ['Central Asia', 'Asia', 46, 35.5, 80, 51],
  ['Eastern Europe', 'Europe', 16, 44, 60, 70],
  ['South Asia', 'Asia', 60.5, 5, 94.5, 35.5],
  ['Philippines', 'Asia', 116, 4.5, 127, 21],
  ['Indonesia and Malaysia', 'Asia', 94, -11, 141, 7],
  ['Mainland Southeast Asia', 'Asia', 94.5, 7, 101.5, 28.5],
  ['Mainland Southeast Asia', 'Asia', 101.5, 7, 110, 23.3],
  ['Eastern China', 'Asia', 97.5, 18, 123, 42],
  ['Japan and Korea', 'Asia', 124.5, 30, 146, 42.5],
  ['Japan and Korea', 'Asia', 139.3, 42.5, 146, 45.7],
  ['Western China and Tibet', 'Asia', 78, 27.5, 97.5, 49],
  ['Manchuria and Amur', 'Asia', 115, 42, 141, 54],
  ['Mongolia', 'Asia', 87, 42, 115, 52],
  ['Siberia', 'Asia', 60, 50, 115, 78],
  ['Russian Far East', 'Asia', 115, 50, 180, 78],
  ['Russian Far East', 'Asia', -180, 60, -168.5, 72],
  ['New Guinea and Melanesia', 'Oceania', 141, -12, 170, 0],
  ['Northern Australia', 'Oceania', 112, -20, 154, -10],
  ['Eastern Australia', 'Oceania', 138, -44, 154.5, -20],
  ['Western Australia', 'Oceania', 112, -36, 138, -20],
  ['New Zealand', 'Oceania', 165, -48, 179, -34],
];
export const REGIONS = [];
const boxRegion = BOXES.map(([name, continent]) => {
  let k = REGIONS.findIndex((r) => r.name === name);
  if (k < 0) { k = REGIONS.length; REGIONS.push({ id: k, name, continent }); }
  return k;
});
REGIONS.push({ id: REGIONS.length, name: 'Islands and open ocean', continent: 'Elsewhere' });

function regionIndex(lat, lon) {
  for (let b = 0; b < BOXES.length; b++) {
    const B = BOXES[b];
    if (lon >= B[2] && lon <= B[4] && lat >= B[3] && lat <= B[5]) return boxRegion[b];
  }
  return REGIONS.length - 1;
}

// ---------------------------------------------------------------- totals

/** Which detections a display mode shows. */
export function shows(f, i, mode) {
  switch (mode) {
    case 'modis': return f.sensor[i] === 0;
    case 'viirs': return f.sensor[i] === 1;
    case 'wildfire': return f.score[i] !== 65535 && f.score[i] >= THRESHOLD * 10000;
    default: return true;
  }
}

/** "Intense" is 2,500 or more detections a day, "Active" 250 or more. */
export const activity = (perDay) => (perDay >= 2500 ? 'intense' : perDay >= 250 ? 'active' : 'quiet');

/** Totals for everything shown, and for each region. `days` = how many days the data covers. */
export function summarize(f, mode, days) {
  if (!f.cosLon) {   // the middle of the fires uses longitude as an angle; worked out once
    f.cosLon = new Float32Array(f.n); f.sinLon = new Float32Array(f.n);
    for (let i = 0; i < f.n; i++) { const a = f.lon[i] * Math.PI / 180; f.cosLon[i] = Math.cos(a); f.sinLon[i] = Math.sin(a); }
  }
  const cosLon = f.cosLon, sinLon = f.sinLon;
  const make = (name, continent, id) => ({
    id, name, continent, count: 0, modis: 0, viirs: 0, scored: 0, wildfire: 0, night: 0, high: 0,
    peak: 0, total: 0, frps: [], latSum: 0, x: 0, y: 0, top: [], lat0: 90, lat1: -90,
  });
  const world = make('Whole world', 'Everywhere', -1);
  const regions = REGIONS.map((r) => make(r.name, r.continent, r.id));
  const cut = THRESHOLD * 10000;
  const add = (t, i, frp, valid) => {
    t.count++;
    if (f.sensor[i]) t.viirs++; else t.modis++;
    const s = f.score[i];
    if (s !== 65535) { t.scored++; if (s >= cut) t.wildfire++; }
    if (f.daynight[i] === 1) t.night++;
    const c = f.conf[i];
    if (c === 103 || (c >= 80 && c <= 100)) t.high++;
    t.total += frp;
    if (valid) t.frps.push(frp);
    const la = f.lat[i];
    t.latSum += la; t.x += cosLon[i]; t.y += sinLon[i];
    if (la < t.lat0) t.lat0 = la;
    if (la > t.lat1) t.lat1 = la;
    if (frp > t.peak) t.peak = frp;
    // Five strongest by fire power (a short insertion, only when it beats the fifth)
    const top = t.top;
    if (top.length < 5 || frp > (f.frp[top[4]] || 0)) {
      let k = Math.min(top.length, 4);
      if (top.length < 5) top.push(i);
      while (k > 0 && (f.frp[top[k - 1]] || 0) < frp) { top[k] = top[k - 1]; k--; }
      top[k] = i;
    }
  };
  for (let i = 0; i < f.n; i++) {
    if (!shows(f, i, mode)) continue;
    const valid = !Number.isNaN(f.frp[i]);
    const frp = valid ? f.frp[i] : 0;
    add(world, i, frp, valid);
    add(regions[f.region[i]], i, frp, valid);
  }
  for (const t of [world, ...regions]) {
    t.lat = t.count ? t.latSum / t.count : 0;
    t.lon = Math.atan2(t.y, t.x) * 180 / Math.PI;
    t.perDay = t.count / Math.max(1, days);
    t.activity = activity(t.perDay);
    if (t.frps.length) {
      const a = Float32Array.from(t.frps), m = a.length >> 1;
      const hi = select(a, m);
      t.median = a.length % 2 ? hi : (select(a, m - 1, m) + hi) / 2;
    } else t.median = null;
    t.frps = null;
  }
  return { world, regions: regions.filter((r) => r.count > 0).sort((a, b) => b.count - a.count) };
}

/** The k-th smallest value of `a` (reorders `a`), without sorting all of it (quickselect).
 *  `end` limits the search to a[0..end), used for the lower middle of an even count. */
function select(a, k, end = a.length) {
  let lo = 0, hi = end - 1;
  while (hi > lo) {
    const pivot = a[(lo + hi) >> 1];
    let i = lo, j = hi;
    while (i <= j) {
      while (a[i] < pivot) i++;
      while (a[j] > pivot) j--;
      if (i <= j) { const t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; }
    }
    if (k <= j) hi = j; else if (k >= i) lo = i; else break;
  }
  if (end === a.length) return a[k];
  let mx = -Infinity; for (let q = 0; q < end; q++) if (a[q] > mx) mx = a[q];   // after select(a, m), a[0..m) holds the m smallest
  return mx;
}

// ---------------------------------------------------------------- formatting

export const grouped = (n) => Math.round(n).toLocaleString('en-US');
export function compact(n) {
  if (n >= 1e6) return `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1)}k`;
  return `${Math.round(n)}`;
}
export function share(part, whole) {
  if (!whole) return '0%';
  const p = (100 * part) / whole;
  return p > 0 && p < 1 ? '<1%' : `${Math.round(p)}%`;
}
export function power(mw) {
  if (mw >= 1000) return `${(mw / 1000).toFixed(1)} GW`;
  if (mw >= 100) return `${Math.round(mw)} MW`;
  return `${mw.toFixed(1)} MW`;
}
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export function utcDay(ms) { const d = new Date(ms); return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`; }
export function utcTime(d) { return `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')} UTC`; }
export function span(h) {
  if (!h.first) return 'No data';
  const a = new Date(h.first), b = new Date(h.last);
  if (a.getUTCMonth() === b.getUTCMonth()) {
    return a.getUTCDate() === b.getUTCDate() ? `${utcDay(h.first)} UTC` : `${utcDay(h.first)} – ${b.getUTCDate()} UTC`;
  }
  return `${utcDay(h.first)} – ${utcDay(h.last)} UTC`;
}
/** Whole UTC days the data touches. */
export function dayCount(h) {
  if (!h.first) return 1;
  return Math.floor(h.last / 86400000) - Math.floor(h.first / 86400000) + 1;
}
export function coordinate(lat, lon, digits = 3) {
  return `${Math.abs(lat).toFixed(digits)}° ${lat >= 0 ? 'N' : 'S'}, ${Math.abs(lon).toFixed(digits)}° ${lon >= 0 ? 'E' : 'W'}`;
}
export function ago(ms) {
  const m = Math.round((Date.now() - ms) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} days ago`;
}
