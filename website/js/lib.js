// lib.js: small helpers shared by the 3D scenes.
import * as THREE from 'three';

export const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
export const isSmall = () => matchMedia('(max-width: 760px)').matches;

/** True if this browser can draw WebGL. */
export function hasWebGL() {
  try {
    const c = document.createElement('canvas');
    return !!(window.WebGLRenderingContext && (c.getContext('webgl2') || c.getContext('webgl')));
  } catch { return false; }
}

/** A renderer with sensible defaults. Pixel density is capped to keep phones fast. */
export function makeRenderer(canvas) {
  const r = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  r.setPixelRatio(Math.min(window.devicePixelRatio || 1, isSmall() ? 1.6 : 2));
  r.setClearColor(0x020305, 1);
  return r;
}

/** Resizes the renderer (and optional effect composer) to fit the canvas's size on the page. */
export function fit(renderer, camera, canvas, composer) {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !h) return;
  renderer.setSize(w, h, false);
  composer?.setSize(w, h);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}

/** Runs `tick(dt, time)` every frame, but only while `el` is on screen, to save battery. */
export function runWhileVisible(el, tick) {
  let raf = 0, last = 0;
  const frame = (t) => {
    const dt = Math.min(0.05, (t - last) / 1000); last = t;
    tick(dt, t / 1000);
    raf = requestAnimationFrame(frame);
  };
  const start = () => { if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); } };
  const stop = () => { cancelAnimationFrame(raf); raf = 0; };
  new IntersectionObserver(([e]) => (e.isIntersecting && !document.hidden ? start() : stop()), { rootMargin: '150px' }).observe(el);
  document.addEventListener('visibilitychange', () => (document.hidden ? stop() : el.getBoundingClientRect().bottom > 0 && el.getBoundingClientRect().top < innerHeight && start()));
}

/** Latitude/longitude (degrees) to a point on a sphere. Longitude 0 faces +z. */
export function latLonToVec3(lat, lon, r = 1, out = new THREE.Vector3()) {
  const phi = THREE.MathUtils.degToRad(lat), lam = THREE.MathUtils.degToRad(lon);
  return out.set(r * Math.cos(phi) * Math.sin(lam), r * Math.sin(phi), r * Math.cos(phi) * Math.cos(lam));
}

/** Reads data/fires.bin, written by the packing script: count, then lat, lon, FRP and sensor arrays. */
export async function loadFires(url) {
  const buf = await (await fetch(url)).arrayBuffer();
  const n = new Uint32Array(buf, 0, 1)[0];
  return {
    n,
    lat: new Int16Array(buf, 4, n),          // degrees × 100
    lon: new Int16Array(buf, 4 + 2 * n, n),  // degrees × 100
    frp: new Uint16Array(buf, 4 + 4 * n, n), // MW × 10
    sensor: new Uint8Array(buf, 4 + 6 * n, n), // 0 = MODIS, 1 = VIIRS
  };
}

/** Reads data/land.bin: evenly spaced points that fall on land. */
export async function loadLand(url) {
  const buf = await (await fetch(url)).arrayBuffer();
  const n = new Uint32Array(buf, 0, 1)[0];
  return { n, lat: new Int16Array(buf, 4, n), lon: new Int16Array(buf, 4 + 2 * n, n) };
}

export const smooth = (t) => t * t * (3 - 2 * t);
export const clamp01 = (t) => Math.min(1, Math.max(0, t));
export const lerp = (a, b, t) => a + (b - a) * t;
/** Interpolates between two angles in degrees, taking the shorter way around. */
export function lerpAngle(a, b, t) {
  const d = ((((b - a) % 360) + 540) % 360) - 180;
  return a + d * t;
}

/** Sensor colors, the same as the Ember app. */
export const COLORS = {
  modis: new THREE.Color('#ee9433'),
  viirs: new THREE.Color('#5aa6e8'),
  ember: new THREE.Color('#ff6b1c'),
};
