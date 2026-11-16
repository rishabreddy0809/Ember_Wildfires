// classifier.js: Ember's wildfire model, for the web.
//
// A line-for-line port of MyApp/ML/WildfireClassifier.swift (model v3): a random forest trained
// in Python on every California detection of 2020 and tested on 2021 to 2023. For each
// detection it gives P(wildfire), the chance the pixel belongs to a real wildfire rather than a
// farm or prescribed burn, an industrial heat source, or a false alarm.
//
// The features must stay identical to ml/train_v3.py. api/_lib/parity.test.js checks this port
// against the same 18,943 reference detections the Swift version is tested on.

'use strict';
const fs = require('node:fs');
const zlib = require('node:zlib');

/** Detections at or above this probability count as wildfire (ml/outputs/swift_threshold.txt). */
const THRESHOLD = 0.6;

const FEATURES = [
  'is_viirs', 'bright_mir', 'bright_tir', 'delta_t', 'frp', 'log_frp', 'frp_density',
  'pixel_area_km2', 'conf_class', 'is_day', 'hour_utc', 'month',
  'n_same_2km_0d', 'n_other_2km_prev1d', 'maxfrp_other_2km_prev1d', 'cross_sensor_confirmed',
  'n_all_5km_0d', 'maxfrp_all_5km_0d', 'sumfrp_all_5km_0d', 'n_all_5km_prevday',
  'n_night_5km_prev1d', 'n_day_5km_prev1d', 'other_sensor_present',
  'lc_forest', 'lc_shrub', 'lc_grass', 'lc_ag', 'lc_dev', 'hist_months',
];

const EARTH_KM = 6371;
const CELL = 0.05;   // degrees; the neighbour search buckets points by UTC day and this cell

// ---------------------------------------------------------------- the forest

/** A scikit-learn random forest exported by ml/export_app_model.py ("EMRF" file). */
class Forest {
  constructor(buf) {
    if (buf.length < 16 || buf.toString('latin1', 0, 4) !== 'EMRF') throw new Error('not a forest file');
    if (buf.readUInt32LE(4) !== 1) throw new Error('unknown forest version');
    const trees = buf.readUInt32LE(8);
    if (buf.readUInt32LE(12) !== FEATURES.length) throw new Error('forest expects other features');
    let off = 16, total = 0;
    const parts = [];
    for (let t = 0; t < trees; t++) {
      const n = buf.readUInt32LE(off); off += 4;
      if (off + n * 22 > buf.length) throw new Error('truncated forest file');
      parts.push({ n, off }); total += n; off += n * 22;
    }
    this.feature = new Int16Array(total);
    this.threshold = new Float64Array(total);
    this.left = new Int32Array(total);
    this.right = new Int32Array(total);
    this.prob = new Float32Array(total);
    this.roots = new Int32Array(trees);
    let base = 0;
    parts.forEach(({ n, off: o }, t) => {
      this.roots[t] = base;
      for (let i = 0; i < n; i++) this.feature[base + i] = buf.readInt16LE(o + 2 * i);
      o += 2 * n;
      for (let i = 0; i < n; i++) this.threshold[base + i] = buf.readDoubleLE(o + 8 * i);
      o += 8 * n;
      for (let i = 0; i < n; i++) this.left[base + i] = buf.readInt32LE(o + 4 * i) + base;   // global indices
      o += 4 * n;
      for (let i = 0; i < n; i++) this.right[base + i] = buf.readInt32LE(o + 4 * i) + base;
      o += 4 * n;
      for (let i = 0; i < n; i++) this.prob[base + i] = buf.readFloatLE(o + 4 * i);
      base += n;
    });
  }

  /** Mean P(wildfire) over all trees, for the row of `x` starting at `at`.
   *  Features are float32, compared against float64 thresholds, like scikit-learn. */
  predict(x, at) {
    const { feature, threshold, left, right, prob, roots } = this;
    let sum = 0;
    for (let t = 0; t < roots.length; t++) {
      let node = roots[t];
      while (feature[node] >= 0) node = x[at + feature[node]] <= threshold[node] ? left[node] : right[node];
      sum = Math.fround(sum + prob[node]);
    }
    return Math.fround(sum / roots.length);
  }
}

// ---------------------------------------------------------------- static grids

/** Land cover (NLCD 2019) and 2017-2019 fire-history months on a 0.01 degree grid over
 *  California ("EMSG" file). Outside the grid every value is missing. */
class StaticGrids {
  constructor(buf) {
    if (buf.length <= 44 || buf.toString('latin1', 0, 4) !== 'EMSG' || buf.readUInt32LE(4) !== 1) throw new Error('not a grid file');
    this.rows = buf.readUInt32LE(8); this.cols = buf.readUInt32LE(12); this.bands = buf.readUInt32LE(16);
    this.lat0 = buf.readDoubleLE(20); this.lon0 = buf.readDoubleLE(28); this.step = buf.readDoubleLE(36);
    this.values = zlib.inflateRawSync(buf.subarray(44));
    if (this.bands !== 6 || this.values.length !== this.rows * this.cols * this.bands) throw new Error('bad grid file');
  }

  /** [forest, shrub, grass, ag, developed] as 0-1 fractions, then fire-history months; null = no data. */
  lookup(lat, lon) {
    const r = Math.floor((lat - this.lat0) / this.step), c = Math.floor((lon - this.lon0) / this.step);
    if (r < 0 || r >= this.rows || c < 0 || c >= this.cols) return null;
    const out = new Array(this.bands);
    for (let b = 0; b < this.bands; b++) {
      const v = this.values[(b * this.rows + r) * this.cols + c];
      out[b] = b === this.bands - 1 ? v : (v === 255 ? null : v / 100);
    }
    return out;
  }
}

// ---------------------------------------------------------------- features

/** Month, hour and minute of a moment (ms since 1970) in UTC. */
function utcParts(ms) {
  const d = new Date(ms);
  return { month: d.getUTCMonth() + 1, hour: d.getUTCHours(), minute: d.getUTCMinutes() };
}

/**
 * One feature row per detection (row-major, FEATURES order), missing values -1.
 * A detection is { lat, lon, viirs (bool), mir, tir, scan, track, frp, time (ms), day (bool),
 * night (bool: anything not flagged "D"), confClass (0 low, 1 nominal, 2 high, or null) }.
 */
function featureMatrix(dets, grids) {
  const n = dets.length, F = FEATURES.length;
  const x = new Float32Array(n * F).fill(-1);
  const rad = Math.PI / 180;
  const latR = new Float64Array(n), lonR = new Float64Array(n), cosLat = new Float64Array(n), dayNum = new Int32Array(n);
  const viirsDays = new Set(), modisDays = new Set();
  const buckets = new Map();
  for (let i = 0; i < n; i++) {
    const d = dets[i];
    latR[i] = d.lat * rad; lonR[i] = d.lon * rad; cosLat[i] = Math.cos(latR[i]);
    dayNum[i] = Math.floor(d.time / 86400000);
    (d.viirs ? viirsDays : modisDays).add(dayNum[i]);
    const key = `${dayNum[i]},${Math.floor(d.lat / CELL)},${Math.floor(d.lon / CELL)}`;
    let b = buckets.get(key); if (!b) buckets.set(key, (b = [])); b.push(i);
  }
  const near = 2 / EARTH_KM, far = 5 / EARTH_KM;
  const dy = Math.ceil(5 / 111.19 / CELL) + 1;

  for (let i = 0; i < n; i++) {
    const p = dets[i], pday = dayNum[i], pf = p.frp ?? 0;
    const pNight = p.night;
    const dx = Math.min(Math.ceil(5 / (111.19 * Math.max(cosLat[i], 0.01)) / CELL) + 1, Math.trunc(360 / CELL));
    const cy = Math.floor(p.lat / CELL), cx = Math.floor(p.lon / CELL);
    // Neighbour counts in one pass over the 5 km / two-day neighbourhood (great-circle, inclusive).
    let same = 0, other = 0, otherMax = 0, all = 0, allMax = 0, allSum = 0, prevDay = 0, night = 0, dayTime = 0;
    for (let day = pday - 1; day <= pday; day++) {
      const today = day === pday;
      for (let y = cy - dy; y <= cy + dy; y++) {
        for (let xx = cx - dx; xx <= cx + dx; xx++) {
          const idx = buckets.get(`${day},${y},${xx}`);
          if (!idx) continue;
          for (const j of idx) {
            const s1 = Math.sin((latR[j] - latR[i]) / 2), s2 = Math.sin((lonR[j] - lonR[i]) / 2);
            const angle = 2 * Math.asin(Math.min(1, Math.sqrt(s1 * s1 + cosLat[i] * cosLat[j] * s2 * s2)));
            if (angle > far) continue;
            const q = dets[j], qf = q.frp ?? 0;
            if (q.night) night++; else dayTime++;
            if (today) { all++; allMax = Math.max(allMax, qf); allSum += qf; } else prevDay++;
            if (angle > near) continue;
            if (q.viirs === p.viirs) { if (today) same++; }
            else { other++; otherMax = Math.max(otherMax, qf); }
          }
        }
      }
    }

    const mir = p.mir, tir = p.tir;
    const area = p.scan != null && p.track != null ? p.scan * p.track : null;
    const t = utcParts(p.time);
    const s = grids ? grids.lookup(p.lat, p.lon) : null;
    const otherPresent = (p.viirs ? modisDays : viirsDays).has(pday);
    const selfNight = pNight ? 1 : 0;
    const row = [
      p.viirs ? 1 : 0,
      mir, tir,
      mir != null && tir != null ? mir - tir : null,
      p.frp,
      p.frp != null ? Math.log1p(Math.max(p.frp, 0)) : null,
      p.frp != null && area != null ? p.frp / area : null,
      area,
      p.confClass,
      p.day ? 1 : 0,
      t.hour + t.minute / 60,
      t.month,
      same - 1,                    // minus itself
      other, otherMax,
      other > 0 ? 1 : 0,
      all - 1,                     // minus itself
      allMax, allSum,              // include itself, as in training
      prevDay,
      night - selfNight,
      dayTime - (1 - selfNight),
      otherPresent ? 1 : 0,
      ...(s ?? [null, null, null, null, null, null]),
    ];
    const at = i * F;
    for (let j = 0; j < F; j++) { const v = row[j]; if (v != null && !Number.isNaN(v)) x[at + j] = v; }
  }
  return x;
}

// ---------------------------------------------------------------- scoring

let model = null;
function loadModel(dir) {
  if (!model) {
    model = {
      forest: new Forest(fs.readFileSync(require('node:path').join(dir, 'ember_rf.bin'))),
      grids: new StaticGrids(fs.readFileSync(require('node:path').join(dir, 'ember_static.bin'))),
    };
  }
  return model;
}

/** P(wildfire) for every detection, as a Float32Array; NaN where it can't be computed
 *  (no time, impossible coordinates). */
function score(dets, { forest, grids }) {
  const usable = [], at = [];
  dets.forEach((d, i) => {
    if (Number.isFinite(d.time) && d.lat >= -90 && d.lat <= 90 && d.lon >= -180 && d.lon <= 180) { usable.push(d); at.push(i); }
  });
  const x = featureMatrix(usable, grids);
  const out = new Float32Array(dets.length).fill(NaN);
  for (let k = 0; k < usable.length; k++) out[at[k]] = forest.predict(x, k * FEATURES.length);
  return out;
}

module.exports = { THRESHOLD, FEATURES, Forest, StaticGrids, featureMatrix, score, loadModel };
