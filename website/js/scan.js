// scan.js: a 3D illustration of how a satellite's pixels stretch across its swath.
//
// Units: 1 = 1 km. The across-track distance is shortened so you can see the pixels,
// but the MODIS pixel size at the edge of the scan (≈4.8 × 2.0 km, ≈9.67× the area)
// follows Giglio et al. (2016). VIIRS growth is drawn milder, for illustration only.

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { makeRenderer, fit, runWhileVisible, reduceMotion, isSmall, COLORS } from './lib.js';

const HALF = 34;                                       // half-width of the drawn swath
const modisScan = (f) => 1 + 3.835 * f * f;            // along-scan growth: 1 → 4.835
const modisTrack = (f) => 1 + 1.0 * f * f;             // along-track growth: 1 → 2.0
const viirsGrow = (f) => 1 + 1.1 * f * f;              // illustrative only

/** Lays pixels side by side from the center outward, each sized for its position in the swath. */
function buildStrip(base, scanFn, trackFn, rows, pitch) {
  const cols = [];
  let x = 0;
  while (x < HALF) {
    const f = Math.min(1, (x + base * scanFn(x / HALF) / 2) / HALF);
    const w = base * scanFn(f), h = base * trackFn(f);
    cols.push({ x: x + w / 2, w, h, f });
    x += w;
  }
  const all = [];
  for (const c of cols) for (const sign of [1, -1]) for (let r = -rows; r <= rows; r++) {
    all.push({ x: sign * c.x, z: r * pitch, w: c.w, h: c.h, f: c.f, row: r });
  }
  return all;
}

function pixelMaterial(color, line) {
  return new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
    uniforms: { uColor: { value: color }, uOpacity: { value: 1 }, uLine: { value: line } },
    vertexShader: /* glsl */`
      attribute vec2 aSize; attribute float aHi;
      varying vec2 vUv; varying vec2 vSize; varying float vHi;
      void main(){ vUv = uv; vSize = aSize; vHi = aHi;
        gl_Position = projectionMatrix * modelViewMatrix * instanceMatrix * vec4(position, 1.); }`,
    fragmentShader: /* glsl */`
      uniform vec3 uColor; uniform float uOpacity; uniform float uLine;
      varying vec2 vUv; varying vec2 vSize; varying float vHi;
      void main(){
        vec2 d = min(vUv, 1. - vUv) * vSize;            // distance to the pixel's edge, in km
        float e = min(d.x, d.y);
        float aa = fwidth(e) * 1.5;
        float border = 1. - smoothstep(uLine, uLine + aa, e);
        // When a pixel is only a few screen pixels wide, fade its outline so distant rows don't turn into a white blur
        float cellPx = min(vSize.x, vSize.y) / max(fwidth(e), 1e-4);
        border *= smoothstep(5., 16., cellPx);
        float a = (0.035 + border * 0.6 + vHi * 0.45) * uOpacity;
        gl_FragColor = vec4(uColor * (1. + vHi * 2.2), a);
      }`,
  });
}

function makeLayer(strip, color, line, y) {
  const geo = new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2);
  const mat = pixelMaterial(color, line);
  const mesh = new THREE.InstancedMesh(geo, mat, strip.length);
  const size = new Float32Array(strip.length * 2), hi = new Float32Array(strip.length);
  const m = new THREE.Matrix4();
  strip.forEach((p, i) => {
    m.makeScale(p.w, 1, p.h).setPosition(p.x, y, p.z);
    mesh.setMatrixAt(i, m);
    size[i * 2] = p.w; size[i * 2 + 1] = p.h;
  });
  geo.setAttribute('aSize', new THREE.InstancedBufferAttribute(size, 2));
  const hiAttr = new THREE.InstancedBufferAttribute(hi, 1); hiAttr.setUsage(THREE.DynamicDrawUsage);
  geo.setAttribute('aHi', hiAttr);
  mesh.frustumCulled = false;
  return { mesh, mat, strip, hi: hiAttr };
}

export function initScan({ canvas, slider, sizeOut, areaOut, segButtons }) {
  const renderer = makeRenderer(canvas);
  const scene = new THREE.Scene();
  scene.fog = new THREE.FogExp2(0x020305, 0.009);
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 500);
  camera.position.set(-12, 30, 50);

  const controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true; controls.enablePan = false;
  controls.minDistance = 22; controls.maxDistance = 95;
  controls.maxPolarAngle = THREE.MathUtils.degToRad(82);
  controls.target.set(0, 7, 0);
  if (isSmall()) { controls.enabled = false; canvas.style.touchAction = 'pan-y'; }

  // Ground: a faint grid
  const grid = new THREE.GridHelper(240, 120, 0x1b2333, 0x0d121b);
  grid.position.y = -0.02; scene.add(grid);

  // Pixels
  const modis = makeLayer(buildStrip(1, modisScan, modisTrack, 9, 1), COLORS.modis, 0.07, 0.03);
  const viirs = makeLayer(buildStrip(0.375, viirsGrow, viirsGrow, 24, 0.375), COLORS.viirs, 0.025, 0.0);
  scene.add(viirs.mesh, modis.mesh);

  // Satellite: body, solar panels, and a glowing core
  const SAT_Y = 24;
  const sat = new THREE.Group();
  const bodyMat = new THREE.MeshBasicMaterial({ color: 0xd8dde8 });
  sat.add(new THREE.Mesh(new THREE.BoxGeometry(1.4, 1.1, 2.2), bodyMat));
  const panelMat = new THREE.MeshBasicMaterial({ color: 0x2a5cff });
  for (const s of [-1, 1]) {
    const p = new THREE.Mesh(new THREE.BoxGeometry(4.2, 0.08, 1.5), panelMat); p.position.x = s * 3; sat.add(p);
    const edge = new THREE.LineSegments(new THREE.EdgesGeometry(p.geometry), new THREE.LineBasicMaterial({ color: 0x8fb3ff }));
    edge.position.copy(p.position); sat.add(edge);
  }
  const lens = new THREE.Mesh(new THREE.SphereGeometry(0.35, 16, 12), new THREE.MeshBasicMaterial({ color: new THREE.Color(4, 2.2, 0.6) }));
  lens.position.y = -0.6; sat.add(lens);
  sat.position.y = SAT_Y; scene.add(sat);

  // Swath fan: two triangles (one per side) from the satellite to the edges of the swath
  const fanGeo = new THREE.BufferGeometry();
  fanGeo.setAttribute('position', new THREE.Float32BufferAttribute([0, SAT_Y, 0, -HALF, 0, 0, HALF, 0, 0], 3));
  const fan = new THREE.Mesh(fanGeo, new THREE.MeshBasicMaterial({ color: 0x5577aa, transparent: true, opacity: 0.035, side: THREE.DoubleSide, depthWrite: false, blending: THREE.AdditiveBlending }));
  scene.add(fan);
  const fanEdges = new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints([
    new THREE.Vector3(0, SAT_Y, 0), new THREE.Vector3(-HALF, 0, 0), new THREE.Vector3(0, SAT_Y, 0), new THREE.Vector3(HALF, 0, 0)]),
    new THREE.LineDashedMaterial({ color: 0x6f89b8, dashSize: 0.8, gapSize: 0.6, transparent: true, opacity: 0.5 }));
  fanEdges.computeLineDistances(); scene.add(fanEdges);

  // Flight direction arrow along the ground track
  const track = new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, 0.05, 9), new THREE.Vector3(0, 0.05, -9)]),
    new THREE.LineDashedMaterial({ color: 0xffffff, dashSize: 0.6, gapSize: 0.5, transparent: true, opacity: 0.35 }));
  track.computeLineDistances(); scene.add(track);

  // The scan beam: from the satellite to the pixel being looked at
  const beamGeo = new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(0, SAT_Y - 0.6, 0), new THREE.Vector3()]);
  const beam = new THREE.Line(beamGeo, new THREE.LineBasicMaterial({ color: new THREE.Color(3, 1.6, 0.3) }));
  scene.add(beam);
  const hit = new THREE.Mesh(new THREE.SphereGeometry(0.28, 16, 12), new THREE.MeshBasicMaterial({ color: new THREE.Color(5, 3, 1) }));
  scene.add(hit);

  // Bloom
  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.35, 0.4, 0.45);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());
  const resize = () => { fit(renderer, camera, canvas, composer); bloom.resolution.set(canvas.clientWidth / 2, canvas.clientHeight / 2); };
  resize(); addEventListener('resize', resize);

  // ---- Highlighting the pixel the beam points at ----
  let f = 0;                                          // 0 = below satellite, 1 = edge of swath
  function highlight() {
    const x = f * (HALF - 0.01);
    let target = null;
    modis.strip.forEach((p, i) => {
      const on = p.row === 0 && p.x > 0 && Math.abs(p.x - x) <= p.w / 2;
      modis.hi.array[i] = on ? 1 : 0;
      if (on) target = p;
    });
    if (!target) target = modis.strip.find((p) => p.row === 0 && p.x > 0);
    // VIIRS pixels that sit under the highlighted MODIS pixel light up too
    viirs.strip.forEach((p, i) => {
      const inside = Math.abs(p.x - target.x) < target.w / 2 && Math.abs(p.z) < target.h / 2;
      viirs.hi.array[i] = inside ? 0.7 : 0;
    });
    modis.hi.needsUpdate = true; viirs.hi.needsUpdate = true;
    beamGeo.attributes.position.setXYZ(1, target.x, 0.05, 0); beamGeo.attributes.position.needsUpdate = true;
    hit.position.set(target.x, 0.1, 0);
    sizeOut.textContent = `${target.w.toFixed(1)} × ${target.h.toFixed(1)} km`;
    areaOut.textContent = `${(target.w * target.h).toFixed(2)}×`;
    slider.style.setProperty('--p', `${f * 100}%`);
  }
  highlight();

  let autoUntil = 0;
  slider.addEventListener('input', () => { f = slider.value / 1000; autoUntil = performance.now() + 6000; highlight(); });

  // MODIS / VIIRS / Both buttons
  const show = { modis: 1, viirs: 1 };
  segButtons.forEach((b) => b.addEventListener('click', () => {
    segButtons.forEach((x) => x.classList.toggle('on', x === b));
    show.modis = b.dataset.show !== 'viirs' ? 1 : 0;
    show.viirs = b.dataset.show !== 'modis' ? 1 : 0;
  }));

  let phase = 0;
  runWhileVisible(canvas, (dt, t) => {
    // When nobody is touching the slider, sweep the scan slowly back and forth
    if (!reduceMotion && performance.now() > autoUntil) {
      phase += dt * 0.22;
      f = 0.5 - 0.5 * Math.cos(phase);
      slider.value = Math.round(f * 1000);
      highlight();
    }
    modis.mat.uniforms.uOpacity.value += (show.modis - modis.mat.uniforms.uOpacity.value) * 0.12;
    viirs.mat.uniforms.uOpacity.value += (show.viirs - viirs.mat.uniforms.uOpacity.value) * 0.12;
    sat.position.y = SAT_Y + Math.sin(t * 1.2) * 0.25;
    if (!controls.enabled && !reduceMotion) {                // phones: slow automatic camera drift
      const a = t * 0.08;
      camera.position.set(Math.sin(a) * 16 - 6, 32, 44 + Math.cos(a) * 5);
      camera.lookAt(0, 7, 0);
    }
    controls.update();
    composer.render();
  });
}
