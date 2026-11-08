// cube.js: a 3D "space-time cube" that shows how DBSCAN clustering works.
// The two flat directions are space (km) and the vertical direction is time (hours).
// All points are a MADE-UP example. Two real fires, one factory, and some lone points.

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { makeRenderer, fit, runWhileVisible, reduceMotion, isSmall, COLORS, smooth, clamp01 } from './lib.js';

const EPS_KM = 1, EPS_H = 24, MIN_PTS = 3;   // the experiment's settings: 1,000 m and 24 hours
const SX = 2.1, ST = 0.27, T0 = 36;          // drawing scale: km → units, hours → units

// Seeded random numbers, so the example looks the same every time
let seed = 11;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const gauss = () => { let u = 0, v = 0; while (!u) u = rnd(); while (!v) v = rnd(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };

function makeExample() {
  const pts = [];
  const add = (x, y, t, truth) => pts.push({ x, y, t, truth, sensor: rnd() < 0.4 ? 0 : 1 });
  // Fire 1: grows and drifts northeast over two days
  for (let t = 0; t <= 54; t += 6) {
    const cx = -3.2 + t * 0.06, cy = -2 + t * 0.035, s = 0.22 + t * 0.008;
    for (let i = 0; i < 4 + Math.round(t / 14); i++) add(cx + gauss() * s, cy + gauss() * s, t + rnd() * 2, 'fire');
  }
  // Fire 2: a short burst
  for (let t = 16; t <= 34; t += 6) for (let i = 0; i < 4; i++) add(3.2 + gauss() * 0.3, 3 + gauss() * 0.3, t + rnd() * 2, 'fire');
  // Factory: the same hot spot every 12 hours
  for (let t = 3; t <= 69; t += 12) for (let i = 0; i < 2; i++) add(4.3 + gauss() * 0.06, -3.4 + gauss() * 0.06, t, 'factory');
  // Lone false alarms scattered around
  let tries = 0;
  while (pts.filter((p) => p.truth === 'noise').length < 9 && tries++ < 500) {
    const p = { x: (rnd() - 0.5) * 10, y: (rnd() - 0.5) * 10, t: rnd() * 72 };
    if (pts.every((q) => Math.hypot(q.x - p.x, q.y - p.y) > 1.6 || Math.abs(q.t - p.t) > 30)) add(p.x, p.y, p.t, 'noise');
  }
  return pts;
}

/** DBSCAN (Ester et al., 1996). Neighbors: within 1 km in space AND 24 h in time. Returns a label per point, -1 = noise. */
function dbscan(pts) {
  const near = (i) => pts.reduce((a, q, j) => (Math.hypot(q.x - pts[i].x, q.y - pts[i].y) <= EPS_KM && Math.abs(q.t - pts[i].t) <= EPS_H ? (a.push(j), a) : a), []);
  const lab = new Array(pts.length).fill(undefined), links = [];
  let c = -1;
  for (let i = 0; i < pts.length; i++) {
    if (lab[i] !== undefined) continue;
    const nb = near(i);
    if (nb.length < MIN_PTS) { lab[i] = -1; continue; }
    lab[i] = ++c;
    const queue = nb.filter((j) => j !== i).map((j) => [i, j]);
    while (queue.length) {
      const [from, j] = queue.shift();
      if (lab[j] === -1) { lab[j] = c; links.push([from, j]); }
      if (lab[j] !== undefined) continue;
      lab[j] = c; links.push([from, j]);
      const nb2 = near(j);
      if (nb2.length >= MIN_PTS) nb2.forEach((k) => queue.push([j, k]));
    }
  }
  return { lab, links };
}

export function initCube({ canvas, labelsEl, runBtn, resetBtn }) {
  const renderer = makeRenderer(canvas);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(38, 1, 0.1, 300);
  camera.position.set(30, 16, 34);
  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true; controls.enablePan = false; controls.minDistance = 25; controls.maxDistance = 80;
  controls.autoRotate = !reduceMotion; controls.autoRotateSpeed = 0.55;
  if (isSmall()) { controls.enableRotate = false; controls.enableZoom = false; canvas.style.touchAction = 'pan-y'; }

  const pts = makeExample();
  const toV = (p) => new THREE.Vector3(p.x * SX, (p.t - T0) * ST, p.y * SX);

  // The cube frame and a grid on the floor
  const W = 11 * SX, H = 76 * ST;
  const frame = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(W * 2, H, W * 2)), new THREE.LineBasicMaterial({ color: 0x2a3344, transparent: true, opacity: 0.8 }));
  frame.position.y = (H / 2) - (T0 + 2) * ST; scene.add(frame);
  const floor = new THREE.GridHelper(W * 2, 12, 0x1e2736, 0x121823); floor.position.y = frame.position.y - H / 2; scene.add(floor);
  // Time "slices" every 24 hours
  for (const t of [24, 48]) {
    const s = new THREE.Mesh(new THREE.PlaneGeometry(W * 2, W * 2).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ color: 0x33e6ff, transparent: true, opacity: 0.025, side: THREE.DoubleSide, depthWrite: false }));
    s.position.y = (t - T0) * ST; scene.add(s);
  }

  // Points (MODIS = circle, VIIRS = diamond)
  const n = pts.length;
  const pos = new Float32Array(n * 3), col = new Float32Array(n * 3), sen = new Float32Array(n), size = new Float32Array(n);
  pts.forEach((p, i) => { const v = toV(p); pos.set([v.x, v.y, v.z], i * 3); sen[i] = p.sensor; size[i] = 1; });
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  g.setAttribute('aColor', new THREE.BufferAttribute(col, 3));
  g.setAttribute('aSensor', new THREE.BufferAttribute(sen, 1));
  g.setAttribute('aSize', new THREE.BufferAttribute(size, 1));
  const pointMat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    uniforms: { uPR: { value: renderer.getPixelRatio() } },
    vertexShader: /* glsl */`
      uniform float uPR; attribute vec3 aColor; attribute float aSensor; attribute float aSize;
      varying vec3 vC; varying float vS;
      void main(){ vec4 mv = modelViewMatrix * vec4(position, 1.); vC = aColor; vS = aSensor;
        gl_PointSize = aSize * 34. * uPR / -mv.z * 10.; gl_Position = projectionMatrix * mv; }`,
    fragmentShader: /* glsl */`
      varying vec3 vC; varying float vS;
      void main(){ vec2 p = gl_PointCoord - .5; float d = mix(length(p), abs(p.x) + abs(p.y), vS) * 2.;
        float core = 1. - smoothstep(.34, .46, d); float glow = exp(-d * d * 5.) * .5;
        float a = core + glow; if (a < .02) discard; gl_FragColor = vec4(vC * (core * 1.5 + glow), a); }`,
  });
  scene.add(new THREE.Points(g, pointMat));

  // Run DBSCAN and prepare the "links" between neighbors (revealed during the animation)
  const { lab, links } = dbscan(pts);
  const linkPos = new Float32Array(links.length * 6);
  links.forEach(([a, b], k) => { const va = toV(pts[a]), vb = toV(pts[b]); linkPos.set([va.x, va.y, va.z, vb.x, vb.y, vb.z], k * 6); });
  const linkGeo = new THREE.BufferGeometry(); linkGeo.setAttribute('position', new THREE.BufferAttribute(linkPos, 3));
  linkGeo.setDrawRange(0, 0);
  const linkMat = new THREE.LineBasicMaterial({ color: new THREE.Color(1.6, 0.7, 0.25), transparent: true, opacity: 0.7, depthWrite: false, blending: THREE.AdditiveBlending });
  scene.add(new THREE.LineSegments(linkGeo, linkMat));

  // Colors: before = sensor colors. After = one color per cluster, gray for noise.
  const clusterColors = [new THREE.Color('#e8622a'), new THREE.Color('#e9b949'), new THREE.Color('#c94f7c'), new THREE.Color('#e0892b')];
  const noiseColor = new THREE.Color('#3a3f4a');
  const startCol = pts.map((p) => (p.sensor ? COLORS.viirs : COLORS.modis));
  const endCol = pts.map((_, i) => (lab[i] < 0 ? noiseColor : clusterColors[lab[i] % clusterColors.length]));

  // HTML labels that follow 3D positions
  const clusters = {};
  pts.forEach((p, i) => { if (lab[i] >= 0) (clusters[lab[i]] ||= []).push(i); });
  const labels = [];
  const addLabel = (text, color, vec, axis = false) => {
    const el = document.createElement('span'); el.textContent = text; el.style.color = color;
    if (axis) el.className = 'axis';
    labelsEl.appendChild(el); labels.push({ el, vec, axis });
  };
  let fireNo = 0;
  Object.entries(clusters).forEach(([c, idx]) => {
    const top = idx.reduce((a, i) => (pts[i].t > pts[a].t ? i : a), idx[0]);
    const isFactory = idx.every((i) => pts[i].truth === 'factory');
    const v = toV(pts[top]).add(new THREE.Vector3(0, 1.2, 0));
    addLabel(isFactory ? `Factory, wrongly grouped as a fire` : `Fire ${++fireNo}: ${idx.length} detections`, '#' + clusterColors[c % clusterColors.length].getHexString(), v);
  });
  const lone = pts.findIndex((_, i) => lab[i] === -1);
  if (lone >= 0) addLabel('Lone points: false alarms', '#c9c5bd', toV(pts[lone]).add(new THREE.Vector3(0, 1.2, 0)));
  addLabel('space', '', new THREE.Vector3(0, floor.position.y, W + 1.5), true);
  addLabel('time (72 h)', '', new THREE.Vector3(-W, frame.position.y + H / 2 + 0.6, W), true);
  addLabel('0 h', '', new THREE.Vector3(-W, floor.position.y - 0.4, W), true);

  // Bloom
  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.45, 0.4, 0.3);
  composer.addPass(bloom); composer.addPass(new OutputPass());
  const resize = () => { fit(renderer, camera, canvas, composer); bloom.resolution.set(canvas.clientWidth / 2, canvas.clientHeight / 2); };
  resize(); addEventListener('resize', resize);

  // Animation state: 0 = raw detections, 1 = fully clustered
  let progress = 0, running = false, runStart = 0;
  function apply(p) {
    const linkT = clamp01(p / 0.6), colorT = smooth(clamp01((p - 0.45) / 0.4));
    linkGeo.setDrawRange(0, Math.floor(links.length * linkT) * 2);
    const c = new THREE.Color();
    for (let i = 0; i < n; i++) {
      c.copy(startCol[i]).lerp(endCol[i], colorT);
      col.set([c.r, c.g, c.b], i * 3);
      size[i] = lab[i] < 0 ? 1 - 0.35 * colorT : 1 + 0.15 * colorT;
    }
    g.attributes.aColor.needsUpdate = true; g.attributes.aSize.needsUpdate = true;
    labels.forEach((l) => { if (!l.axis) l.el.classList.toggle('on', p >= 0.95); });
  }
  apply(0);
  runBtn.addEventListener('click', () => { running = true; runStart = performance.now(); if (reduceMotion) { running = false; progress = 1; apply(1); } });
  resetBtn.addEventListener('click', () => { running = false; progress = 0; apply(0); });

  const v = new THREE.Vector3();
  runWhileVisible(canvas, (dt, t) => {
    if (running) {
      progress = Math.min(1, (performance.now() - runStart) / 3200);
      apply(progress);
      if (progress >= 1) running = false;
    }
    if (!controls.enableRotate && !reduceMotion) {           // phones: rotate the camera automatically
      const a = t * 0.15; camera.position.set(Math.sin(a) * 46, 16, Math.cos(a) * 46); camera.lookAt(0, 0, 0);
    }
    controls.update();
    composer.render();
    // Move the HTML labels to their 3D positions
    const w = canvas.clientWidth, h = canvas.clientHeight;
    for (const l of labels) {
      v.copy(l.vec).project(camera);
      const hidden = v.z > 1;
      const half = l.el.offsetWidth / 2 + 6;
      l.el.style.left = `${Math.min(w - half, Math.max(half, (v.x * 0.5 + 0.5) * w))}px`;
      l.el.style.top = `${(-v.y * 0.5 + 0.5) * h}px`;
      l.el.style.visibility = hidden ? 'hidden' : 'visible';
    }
  });
}
