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

/** Downloads a .pack file (see tools/pack.py) and returns its bytes, un-gzipped.
 *  If the server already un-gzipped it on the way, the bytes are used as they are. */
async function unpack(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: ${res.status}`);
  let bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
    bytes = new Uint8Array(await new Response(stream).arrayBuffer());
  }
  return bytes;
}

/** Reads the columns of a .pack: lat and lon as running differences, 16-bit columns split
 *  into low bytes then high bytes, 8-bit columns as they are. */
function readColumns(bytes, names) {
  const n = new DataView(bytes.buffer, bytes.byteOffset, 4).getUint32(0, true);
  const out = { n };
  let at = 4;
  for (const name of names) {
    if (name === 'sensor') { out[name] = bytes.slice(at, at + n); at += n; continue; }
    const lo = bytes.subarray(at, at + n), hi = bytes.subarray(at + n, at + 2 * n);
    at += 2 * n;
    if (name === 'frp') {
      const a = new Uint16Array(n);
      for (let i = 0; i < n; i++) a[i] = lo[i] | (hi[i] << 8);
      out[name] = a;
    } else {
      // Int16Array wraps on assignment, which undoes the "mod 2^16" in the packer exactly.
      const a = new Int16Array(n);
      let v = 0;
      for (let i = 0; i < n; i++) { v = (v + (lo[i] | (hi[i] << 8))) & 0xffff; a[i] = v; }
      out[name] = a;
    }
  }
  return out;
}

// The globe and the app preview both use these; download and decode each only once.
const cache = new Map();
const once = (key, make) => { if (!cache.has(key)) cache.set(key, make()); return cache.get(key); };

/** Every detection: lat and lon (degrees x 100), frp (MW x 10), sensor (0 = MODIS, 1 = VIIRS). */
export const loadFires = (url) => once(url, async () => readColumns(await unpack(url), ['lat', 'lon', 'frp', 'sensor']));

/** Evenly spaced points that fall on land, for the globe's dot-matrix continents. */
export const loadLand = (url) => once(url, async () => readColumns(await unpack(url), ['lat', 'lon']));

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
