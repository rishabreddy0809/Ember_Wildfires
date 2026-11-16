// Checks the web port of the wildfire model against the Python reference.
//   node website/api/_lib/parity.test.js      (from the repo root)
// Same check as ml/swift_tests/parity: 18,943 real detections with the features and
// probabilities Python computed (ml/outputs/swift_golden.csv).

'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { FEATURES, THRESHOLD, featureMatrix, score, loadModel } = require('./classifier.js');

const root = path.join(__dirname, '..', '..', '..');
const model = loadModel(path.join(__dirname, '..', '_model'));
const pyThreshold = parseFloat(fs.readFileSync(path.join(root, 'ml/outputs/swift_threshold.txt'), 'utf8'));
console.log(`threshold python ${pyThreshold} web ${THRESHOLD} ${pyThreshold === THRESHOLD ? 'OK' : 'MISMATCH'}`);

const lines = fs.readFileSync(path.join(root, 'ml/outputs/swift_golden.csv'), 'utf8').trim().split('\n');
const header = lines.shift().split(',');
const col = (name) => header.indexOf(name);
const num = (s) => (s === '' ? null : Number(s));
const checked = FEATURES.map((name, j) => [name, j]).filter(([name]) => header.includes(name));

const dets = [], expected = [];
for (const line of lines) {
  const c = line.split(',');
  const [date, hhmm] = c[col('time')].split(' ');
  const cls = Math.trunc(Number(c[col('conf_class')]));
  const day = c[col('is_day')] === '1';
  dets.push({
    lat: Number(c[col('lat')]), lon: Number(c[col('lon')]), viirs: c[col('sensor')] !== 'MODIS',
    mir: num(c[col('bright_mir')]), tir: num(c[col('bright_tir')]), scan: num(c[col('scan')]), track: num(c[col('track')]),
    frp: num(c[col('frp')]), time: Date.parse(`${date}T${hhmm.slice(0, 2)}:${hhmm.slice(2)}:00Z`),
    day, night: !day, confClass: cls < 0 ? null : cls,
  });
  expected.push({ feats: checked.map(([name]) => num(c[col(name)]) ?? -1), prob: Number(c[col('prob')]) });
}

const t0 = Date.now();
const x = featureMatrix(dets, model.grids);
const p = score(dets, model);
console.log(`rows ${dets.length}, ${checked.length} context/static features checked, features+inference ${((Date.now() - t0) / 1000).toFixed(2)} s`);

let mismatch = 0, maxDiff = 0, flips = 0;
dets.forEach((d, i) => {
  checked.forEach(([name, j], k) => {
    const e = expected[i].feats[k], s = x[i * FEATURES.length + j];
    if (Math.abs(s - e) > 1e-3 * Math.max(1, Math.abs(e))) { if (++mismatch <= 8) console.log(`row ${i} ${name} web ${s} python ${e}`); }
  });
  maxDiff = Math.max(maxDiff, Math.abs(p[i] - expected[i].prob));
  if ((p[i] >= pyThreshold) !== (expected[i].prob >= pyThreshold)) flips++;
});
console.log(`feature mismatches: ${mismatch}, max |prob diff|: ${maxDiff}, decisions that differ: ${flips}`);
process.exit(mismatch === 0 && flips === 0 && maxDiff < 1e-4 ? 0 : 1);
