// /api/fires: every fire NASA FIRMS has seen worldwide in the last 48 hours, scored by Ember's
// wildfire model, packed small for the web app (app/).
//
// It reads FIRMS's public 48-hour global files (MODIS and NOAA-20 VIIRS), which need no API key
// but can't be read by a browser directly. Vercel's CDN keeps each answer for 30 minutes, so
// NASA is asked at most twice an hour however many people visit.
//
// Response (gzip): "EMBR", uint32 header length, a JSON header, padding to 4 bytes, then one
// array per column, each n long (see COLUMNS). app/js/data.js reads it.

'use strict';
const path = require('node:path');
const zlib = require('node:zlib');
const { score, loadModel, THRESHOLD } = require('./_lib/classifier.js');

const SOURCES = {
  modis: 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/modis-c6.1/csv/MODIS_C6_1_Global_48h.csv',
  viirs: 'https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-20-viirs-c2/csv/J1_VIIRS_C2_Global_48h.csv',
};

// Column order and types in the packed answer, chosen to stay small (about 26 bytes a fire
// before compression). "Missing" is NaN for floats and 0 or 65535 for ints, as noted.
const COLUMNS = [
  // Degrees x 100,000 (FIRMS's own precision), each as the change from the row before: fires
  // arrive in scan order, so neighbours are close and the small numbers compress well.
  ['lat', Int32Array], ['lon', Int32Array],
  ['frp', Float32Array],     // megawatts
  ['bright', Uint16Array], ['bright2', Uint16Array],   // kelvin x 10; 0 = missing
  ['scan', Uint8Array], ['track', Uint8Array],         // pixel size, km x 50; 0 = missing
  ['minute', Uint16Array],   // minutes after header.minute0 (UTC); 65535 = missing
  ['score', Uint16Array],    // P(wildfire) x 10000; 65535 = not scored
  ['sensor', Uint8Array],    // 0 MODIS, 1 VIIRS
  ['conf', Uint8Array],      // MODIS 0-100 %; VIIRS 101 low, 102 nominal, 103 high; 255 unknown
  ['daynight', Uint8Array],  // 0 day, 1 night, 2 unknown
  ['sat', Uint8Array],       // index into header.satellites
];

async function download(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(40000), headers: { 'user-agent': 'Ember web app' } });
  if (!res.ok) throw new Error(`${res.status} from FIRMS`);
  return { text: await res.text(), lastModified: res.headers.get('last-modified') };
}

/** Parses one FIRMS CSV into detections. Rows without a position are skipped. */
function parse(text, viirs, satellites, out) {
  const lines = text.split('\n');
  const head = lines[0].trim().split(',');
  const c = (...names) => names.map((n) => head.indexOf(n)).find((i) => i >= 0);
  const iLat = c('latitude'), iLon = c('longitude'), iB = c('brightness', 'bright_ti4'), iB2 = c('bright_t31', 'bright_ti5');
  const iScan = c('scan'), iTrack = c('track'), iDate = c('acq_date'), iTime = c('acq_time'), iSat = c('satellite');
  const iConf = c('confidence'), iVer = c('version'), iFrp = c('frp'), iDn = c('daynight');
  const num = (s) => { if (s === undefined || s === '') return null; const v = Number(s); return Number.isFinite(v) ? v : null; };
  let version = '', skipped = 0;
  for (let k = 1; k < lines.length; k++) {
    const line = lines[k].trim();
    if (!line) continue;
    const f = line.split(',');
    const lat = num(f[iLat]), lon = num(f[iLon]);
    if (lat === null || lon === null || lat < -90 || lat > 90 || lon < -180 || lon > 180) { skipped++; continue; }
    const hhmm = (f[iTime] || '').trim().padStart(4, '0');
    const time = Date.parse(`${f[iDate]}T${hhmm.slice(0, 2)}:${hhmm.slice(2, 4)}:00Z`);
    const dn = (f[iDn] || '').trim().toUpperCase();
    const confRaw = (f[iConf] || '').trim().toLowerCase();
    let conf = 255, confClass = null;
    if (viirs) {
      const rank = { l: 0, low: 0, n: 1, nominal: 1, h: 2, high: 2 }[confRaw];
      if (rank !== undefined) { conf = 101 + rank; confClass = rank; }
    } else if (/^\d+$/.test(confRaw)) {
      const p = Number(confRaw);
      conf = Math.min(p, 100);
      confClass = p <= 29 ? 0 : p <= 79 ? 1 : p <= 100 ? 2 : null;
    }
    const sat = (f[iSat] || '').trim();
    if (!satellites.includes(sat)) satellites.push(sat);
    version ||= (f[iVer] || '').trim();
    out.push({
      lat, lon, viirs, frp: num(f[iFrp]), mir: num(f[iB]), tir: num(f[iB2]), scan: num(f[iScan]), track: num(f[iTrack]),
      time: Number.isFinite(time) ? time : NaN, day: dn === 'D', night: dn !== 'D', dn: dn === 'D' ? 0 : dn === 'N' ? 1 : 2,
      conf, confClass, sat: satellites.indexOf(sat),
    });
  }
  return { version, skipped };
}

function pack(dets, scores, header) {
  const n = dets.length, minute0 = header.minute0;
  const cols = Object.fromEntries(COLUMNS.map(([name, T]) => [name, new T(n)]));
  const nan = (v) => (v === null || v === undefined ? NaN : v);
  let prevLat = 0, prevLon = 0;
  const q = (v, k, max) => (v === null || v === undefined || v <= 0 ? 0 : Math.min(max, Math.round(v * k)));
  dets.forEach((d, i) => {
    const lat = Math.round(d.lat * 1e5), lon = Math.round(d.lon * 1e5);
    cols.lat[i] = lat - prevLat; cols.lon[i] = lon - prevLon; prevLat = lat; prevLon = lon;
    cols.frp[i] = nan(d.frp);
    cols.bright[i] = q(d.mir, 10, 65535); cols.bright2[i] = q(d.tir, 10, 65535);
    cols.scan[i] = q(d.scan, 50, 255); cols.track[i] = q(d.track, 50, 255);
    const m = Number.isFinite(d.time) ? Math.round(d.time / 60000) - minute0 : -1;
    cols.minute[i] = m >= 0 && m < 65535 ? m : 65535;
    cols.score[i] = Number.isNaN(scores[i]) ? 65535 : Math.round(scores[i] * 10000);
    cols.sensor[i] = d.viirs ? 1 : 0; cols.conf[i] = d.conf; cols.daynight[i] = d.dn; cols.sat[i] = d.sat;
  });
  const json = Buffer.from(JSON.stringify({ ...header, n, columns: COLUMNS.map(([name, T]) => [name, T.name]) }));
  const pad = (4 - ((8 + json.length) % 4)) % 4;
  const head = Buffer.alloc(8 + json.length + pad);
  head.write('EMBR', 0, 'latin1'); head.writeUInt32LE(json.length, 4); json.copy(head, 8);
  return Buffer.concat([head, ...COLUMNS.map(([name]) => Buffer.from(cols[name].buffer))]);
}

module.exports = async function handler(req, res) {
  try {
    const started = Date.now();
    const [modis, viirs] = await Promise.allSettled([download(SOURCES.modis), download(SOURCES.viirs)]);
    if (modis.status === 'rejected' && viirs.status === 'rejected') throw new Error(`FIRMS unreachable: ${viirs.reason.message}`);

    const satellites = [], dets = [], info = {};
    for (const [name, r, isViirs] of [['modis', modis, false], ['viirs', viirs, true]]) {
      if (r.status === 'rejected') { info[name] = { error: r.reason.message }; continue; }
      const before = dets.length;
      const { version, skipped } = parse(r.value.text, isViirs, satellites, dets);
      info[name] = { count: dets.length - before, skipped, version, lastModified: r.value.lastModified };
    }
    // Oldest first, so the newest detections are drawn on top.
    dets.sort((a, b) => (a.time || 0) - (b.time || 0));

    const scores = score(dets, loadModel(path.join(__dirname, '_model')));
    const times = dets.map((d) => d.time).filter(Number.isFinite);   // sorted, oldest first
    const raw = pack(dets, scores, {
      v: 1,
      fetchedAt: new Date().toISOString(),
      first: times.length ? times[0] : null,
      last: times.length ? times[times.length - 1] : null,
      minute0: times.length ? Math.round(times[0] / 60000) : 0,
      sources: info,
      satellites,
      threshold: THRESHOLD,
      ms: Date.now() - started,
    });
    // Compressed here, because Vercel caps a function's answer at 4.5 MB before its own compression.
    const br = /\bbr\b/.test(req.headers?.['accept-encoding'] || '');
    const body = br
      ? zlib.brotliCompressSync(raw, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 7, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: raw.length } })
      : zlib.gzipSync(raw, { level: 9 });

    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Encoding', br ? 'br' : 'gzip');
    res.setHeader('Vary', 'Accept-Encoding');
    res.setHeader('Cache-Control', 'public, max-age=300, s-maxage=1800, stale-while-revalidate=86400');
    res.end(body);
  } catch (e) {
    res.statusCode = 502;
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cache-Control', 'no-store');
    res.end(JSON.stringify({ error: String(e.message || e) }));
  }
};
