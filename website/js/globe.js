// globe.js: the pinned 3D Earth at the top of the page.
//
// • Land is drawn as a dot matrix (from Natural Earth, public domain).
// • Every glowing point is a REAL fire detection from NASA FIRMS (24-hour global files).
// • The page opens on the planet's horizon. The fires switch on in a wave (the "ignition"),
//   in step with the big counter in the headline.
// • As you scroll, the camera moves through "keyframes": horizon → Africa → satellites → California.
// • Bloom post-processing makes the fires glow.

import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { makeRenderer, fit, latLonToVec3, loadFires, loadLand, reduceMotion, isSmall,
         smooth, clamp01, lerp, lerpAngle, COLORS } from './lib.js';

// Camera "keyframes", one per story step. lon/lat = the point on Earth facing the camera.
// dist = camera distance (Earth radius = 1). shift = how far right of center the globe sits, and
// drop = how far below center (both as a fraction of the screen). dropM is `drop` on phones,
// where the globe sits above the text instead of beside it.
const KEYS = [
  { lon: null,   lat: -56, dist: 1.72, shift: 0,    drop: 1.13, dropM: 0.80,  sensor: 0, size: 0.46, sats: 0 },  // 0 hero: the horizon, slowly turning
  { lon: 18,     lat: 4,   dist: 2.45, shift: 0.17, drop: 0,    dropM: -0.16, sensor: 0, size: 0.5,  sats: 0 },  // 1 Africa: where most fires are
  { lon: -40,    lat: 12,  dist: 3.40, shift: 0.17, drop: 0,    dropM: -0.16, sensor: 1, size: 0.5,  sats: 1 },  // 2 satellites + sensor colors
  { lon: -119.6, lat: 37.4, dist: 1.55, shift: 0.17, drop: 0,   dropM: -0.16, sensor: 1, size: 0.55, sats: 0 },  // 3 California
  { lon: -119.6, lat: 37.4, dist: 1.38, shift: 0.17, drop: 0,   dropM: -0.16, sensor: 1, size: 0.6,  sats: 0 },  // 4 hold
];

// Where the hero starts: Africa, where most of the day's fires are, faces the camera.
const START_LON = 14;

export async function initGlobe({ canvas, story, onReady, onProgress }) {
  const renderer = makeRenderer(canvas);
  renderer.setClearColor(0x020305, 1);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(40, 1, 0.01, 200);

  // Groups: world (moves the globe to the right) → tilt (latitude) → spin (longitude) → Earth
  const world = new THREE.Group(); scene.add(world);
  const tilt = new THREE.Group(); world.add(tilt);
  const spin = new THREE.Group(); tilt.add(spin);

  // ---- Earth body: dark sphere with a soft blue rim ----
  const bodyMat = new THREE.ShaderMaterial({
    vertexShader: /* glsl */`
      varying vec3 vN; varying vec3 vV;
      void main(){ vec4 mv = modelViewMatrix * vec4(position,1.); vN = normalize(normalMatrix*normal); vV = normalize(-mv.xyz); gl_Position = projectionMatrix*mv; }`,
    fragmentShader: /* glsl */`
      varying vec3 vN; varying vec3 vV;
      void main(){ float f = pow(1. - max(dot(vN, vV), 0.), 3.0);
        vec3 c = mix(vec3(0.004,0.006,0.012), vec3(0.03,0.09,0.22), f);
        gl_FragColor = vec4(c, 1.); }`,
  });
  spin.add(new THREE.Mesh(new THREE.SphereGeometry(1, 128, 96), bodyMat));

  // ---- Atmosphere: glowing shell around the planet ----
  const atmo = new THREE.Mesh(new THREE.SphereGeometry(1.16, 96, 64), new THREE.ShaderMaterial({
    side: THREE.BackSide, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    vertexShader: /* glsl */`varying vec3 vN; void main(){ vN = normalize(normalMatrix*normal); gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.); }`,
    fragmentShader: /* glsl */`varying vec3 vN; void main(){ float i = pow(clamp(0.72 - dot(vN, vec3(0.,0.,1.)), 0., 1.), 3.2);
      gl_FragColor = vec4(vec3(0.10,0.36,1.0) * i * 1.1, i); }`,
  }));
  tilt.add(atmo);

  // ---- Stars ----
  {
    const n = 2200, p = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      const v = new THREE.Vector3().randomDirection().multiplyScalar(40 + Math.random() * 30);
      p.set([v.x, v.y, v.z], i * 3);
    }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.BufferAttribute(p, 3));
    scene.add(new THREE.Points(g, new THREE.PointsMaterial({ color: 0x8899bb, size: 0.09, sizeAttenuation: true, transparent: true, opacity: 0.55, depthWrite: false })));
  }

  // ---- Load data (land dots + fire detections) ----
  const [land, fires] = await Promise.all([loadLand('data/land.bin'), loadFires('data/fires.bin')]);

  // Land: a dot matrix that fades out on the far side of the planet
  {
    const pos = new Float32Array(land.n * 3), v = new THREE.Vector3();
    for (let i = 0; i < land.n; i++) { latLonToVec3(land.lat[i] / 100, land.lon[i] / 100, 1.001, v); pos.set([v.x, v.y, v.z], i * 3); }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    const m = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false,
      uniforms: { uSize: { value: 1 }, uPR: { value: renderer.getPixelRatio() } },
      vertexShader: /* glsl */`
        uniform float uSize; uniform float uPR; varying float vA;
        void main(){ vec4 mv = modelViewMatrix*vec4(position,1.);
          vec3 n = normalize(normalMatrix*position); vA = smoothstep(0.0, 0.35, dot(n, normalize(-mv.xyz)));
          gl_PointSize = clamp(uSize * uPR * 2.6 / -mv.z, 1.0, 6.0 * uPR); gl_Position = projectionMatrix*mv; }`,
      fragmentShader: /* glsl */`
        varying float vA; void main(){ vec2 p = gl_PointCoord-.5; if (dot(p,p) > .25) discard;
          gl_FragColor = vec4(vec3(0.16,0.24,0.38), vA * 0.9); }`,
    });
    spin.add(new THREE.Points(g, m));
  }

  // Fires: one point per detection. MODIS = circle, VIIRS = diamond, size grows with FRP.
  const fireUniforms = {
    uTime: { value: 0 }, uPR: { value: renderer.getPixelRatio() }, uSize: { value: 1 },
    uSensorMix: { value: 0 }, uModis: { value: COLORS.modis }, uViirs: { value: COLORS.viirs },
    uViewH: { value: 800 },
    uReveal: { value: reduceMotion ? 1 : 0 },   // 0 = no fires lit yet, 1 = all lit (the ignition)
  };
  {
    const n = fires.n, pos = new Float32Array(n * 3), aS = new Float32Array(n), aF = new Float32Array(n), aR = new Float32Array(n), aI = new Float32Array(n);
    const v = new THREE.Vector3();
    for (let i = 0; i < n; i++) {
      const lon = fires.lon[i] / 100;
      latLonToVec3(fires.lat[i] / 100, lon, 1.002, v);
      pos.set([v.x, v.y, v.z], i * 3);
      aS[i] = fires.sensor[i]; aF[i] = fires.frp[i] / 10; aR[i] = Math.random();
      // When this fire lights up during the ignition (0 = first, 1 = last). On the side facing
      // the camera the fires light in a wave from west to east. On the far side, in random order.
      const across = ((((lon - (START_LON - 90)) % 360) + 360) % 360) / 180;   // 0..1 across the visible face
      aI[i] = (across <= 1 ? across : Math.random()) * 0.86 + Math.random() * 0.14;
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('aSensor', new THREE.BufferAttribute(aS, 1));
    g.setAttribute('aFrp', new THREE.BufferAttribute(aF, 1));
    g.setAttribute('aRand', new THREE.BufferAttribute(aR, 1));
    g.setAttribute('aIgnite', new THREE.BufferAttribute(aI, 1));
    const m = new THREE.ShaderMaterial({
      uniforms: fireUniforms, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
      vertexShader: /* glsl */`
        uniform float uTime, uPR, uSize, uSensorMix, uViewH, uReveal; uniform vec3 uModis, uViirs;
        attribute float aSensor, aFrp, aRand, aIgnite;
        varying vec3 vColor; varying float vSensor; varying float vA;
        void main(){
          vec4 mv = modelViewMatrix * vec4(position, 1.);
          vec3 n = normalize(normalMatrix * position);
          vA = smoothstep(-0.02, 0.3, dot(n, normalize(-mv.xyz)));           // hide the far side
          float lf = log(1. + aFrp) / log(10.);                               // log10(1 + FRP)
          float flicker = 0.82 + 0.18 * sin(uTime * (2. + aRand * 3.) + aRand * 40.);
          // Ignition: the fire is off until the wave reaches it, then flashes white and settles.
          float since = uReveal * 1.12 - aIgnite;
          float lit = smoothstep(0., 0.012, since);
          float flash = exp(-max(since, 0.) * 26.) * lit * (1. - step(1., uReveal));
          float worldSize = 0.0085 * uSize * (0.75 + 0.55 * lf) * flicker * lit * (1. + 1.6 * flash);    // in Earth radii
          gl_PointSize = min(worldSize * uViewH / -mv.z, 70. * uPR);
          // "heat" colors: dull red for weak fires → white-yellow for intense ones
          float t = clamp(lf / 2.6, 0., 1.);
          vec3 heat = mix(vec3(0.9, 0.12, 0.02), vec3(1.0, 0.55, 0.08), smoothstep(0., .5, t));
          heat = mix(heat, vec3(1.0, 0.92, 0.6), smoothstep(.55, 1., t));
          vColor = mix(heat, aSensor < .5 ? uModis : uViirs, uSensorMix);
          vColor = mix(vColor, vec3(1.0, 0.95, 0.8), flash * 0.8);
          vA *= lit;
          vSensor = aSensor;
          gl_Position = projectionMatrix * mv;
        }`,
      fragmentShader: /* glsl */`
        uniform float uSensorMix; varying vec3 vColor; varying float vSensor; varying float vA;
        void main(){
          vec2 p = gl_PointCoord - .5;
          float circle = length(p) * 2.;
          float diamond = (abs(p.x) + abs(p.y)) * 2.;
          float d = mix(circle, mix(circle, diamond, vSensor), uSensorMix);   // shapes appear with sensor colors
          float core = 1. - smoothstep(.28, .42, d);
          float glow = exp(-d * d * 6.) * .4;
          float a = (core * .75 + glow) * vA;
          if (a < .01) discard;
          gl_FragColor = vec4(vColor * (core * .7 + glow * .8), a);
        }`,
    });
    spin.add(new THREE.Points(g, m));
  }

  // ---- Two illustrative satellites with orbits and scanning swaths ----
  const sats = [];
  const satGroup = new THREE.Group(); tilt.add(satGroup);
  function makeSat(color, incl, raan, phase, speed, halfSwath) {
    const R = 1.2;
    const q = new THREE.Quaternion().setFromEuler(new THREE.Euler(THREE.MathUtils.degToRad(incl), THREE.MathUtils.degToRad(raan), 0, 'YXZ'));
    const u = new THREE.Vector3(1, 0, 0).applyQuaternion(q), w = new THREE.Vector3(0, 0, 1).applyQuaternion(q);
    const normal = new THREE.Vector3().crossVectors(u, w).normalize();
    // orbit ring
    const ring = []; for (let i = 0; i <= 256; i++) { const a = i / 256 * Math.PI * 2; ring.push(u.clone().multiplyScalar(Math.cos(a) * R).add(w.clone().multiplyScalar(Math.sin(a) * R))); }
    const orbit = new THREE.Line(new THREE.BufferGeometry().setFromPoints(ring), new THREE.LineBasicMaterial({ color, transparent: true, opacity: 0, depthWrite: false }));
    // satellite body: a bright core plus small solar panels
    const body = new THREE.Group();
    const core = new THREE.Mesh(new THREE.OctahedronGeometry(0.03), new THREE.MeshBasicMaterial({ color: color.clone().multiplyScalar(3), transparent: true }));
    const panelMat = new THREE.MeshBasicMaterial({ color: color.clone().multiplyScalar(0.9), transparent: true, side: THREE.DoubleSide });
    const p1 = new THREE.Mesh(new THREE.PlaneGeometry(0.08, 0.026), panelMat); p1.position.x = 0.065;
    const p2 = p1.clone(); p2.position.x = -0.04;
    body.add(core, p1, p2);
    // swath: a see-through triangle from the satellite down to the ground
    const swGeo = new THREE.BufferGeometry(); swGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(9), 3));
    const swath = new THREE.Mesh(swGeo, new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0, side: THREE.DoubleSide, depthWrite: false, blending: THREE.AdditiveBlending }));
    // scan line on the ground
    const scanGeo = new THREE.BufferGeometry(); scanGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(17 * 3), 3));
    const scan = new THREE.Line(scanGeo, new THREE.LineBasicMaterial({ color: color.clone().multiplyScalar(2), transparent: true, opacity: 0, depthWrite: false }));
    satGroup.add(orbit, body, swath, scan);
    sats.push({ u, w, normal, R, phase, speed, halfSwath, orbit, body, swath, scan, mats: [orbit.material, core.material, panelMat, swath.material, scan.material] });
  }
  makeSat(COLORS.modis, 98, 30, 0.6, 0.16, 0.18);    // MODIS-like (swath ≈ 2,330 km)
  makeSat(COLORS.viirs, 98, -55, 2.4, 0.13, 0.24);   // VIIRS-like (swath ≈ 3,060 km)

  const tmp = new THREE.Vector3(), a = new THREE.Vector3(), b = new THREE.Vector3();
  function updateSats(t, vis) {
    for (const s of sats) {
      const ang = s.phase + t * s.speed;
      const pos = s.u.clone().multiplyScalar(Math.cos(ang) * s.R).add(s.w.clone().multiplyScalar(Math.sin(ang) * s.R));
      s.body.position.copy(pos);
      s.body.lookAt(0, 0, 0);
      const sub = pos.clone().normalize();
      a.copy(sub).addScaledVector(s.normal, s.halfSwath).normalize().multiplyScalar(1.004);
      b.copy(sub).addScaledVector(s.normal, -s.halfSwath).normalize().multiplyScalar(1.004);
      const arr = s.swath.geometry.attributes.position.array;
      arr.set([pos.x, pos.y, pos.z, a.x, a.y, a.z, b.x, b.y, b.z]);
      s.swath.geometry.attributes.position.needsUpdate = true;
      // scan line follows the curve of the Earth between the two swath edges
      const sa = s.scan.geometry.attributes.position.array;
      const sweep = (Math.sin(t * 6 + s.phase) * 0.5 + 0.5);   // a bright scanning mirror sweeping side to side
      for (let i = 0; i <= 16; i++) { tmp.lerpVectors(a, b, i / 16).normalize().multiplyScalar(1.005); sa.set([tmp.x, tmp.y, tmp.z], i * 3); }
      s.scan.geometry.attributes.position.needsUpdate = true;
      s.mats[0].opacity = 0.6 * vis; s.mats[1].opacity = vis; s.mats[2].opacity = vis;
      s.mats[3].opacity = (0.1 + 0.08 * sweep) * vis; s.mats[4].opacity = 0.9 * vis;
      satGroup.visible = vis > 0.01;
    }
  }

  // ---- Post-processing: bloom makes bright things glow ----
  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.5, 0.4, 0.35);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  function resize() {
    fit(renderer, camera, canvas, composer);
    fireUniforms.uViewH.value = canvas.clientHeight * renderer.getPixelRatio() / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)));
    bloom.resolution.set(canvas.clientWidth / (isSmall() ? 2 : 1.5), canvas.clientHeight / (isSmall() ? 2 : 1.5));
  }
  resize();
  addEventListener('resize', resize);

  // ---- Scroll → which step we're on (a fractional number, e.g. 2.4) ----
  let stepF = 0;
  function readScroll() {
    const r = story.getBoundingClientRect();
    const total = r.height - innerHeight;
    const p = clamp01(-r.top / Math.max(1, total));
    stepF = p * (KEYS.length - 1);
    onProgress?.(p, stepF);
  }
  addEventListener('scroll', readScroll, { passive: true });
  readScroll();

  // Gentle mouse parallax
  const mouse = { x: 0, y: 0, tx: 0, ty: 0 };
  addEventListener('pointermove', (e) => { mouse.tx = (e.clientX / innerWidth - 0.5); mouse.ty = (e.clientY / innerHeight - 0.5); }, { passive: true });

  // ---- Animation loop ----
  let spinLon = START_LON, time = 0, visible = true, raf = 0;
  const cur = { lon: START_LON, lat: KEYS[0].lat, dist: KEYS[0].dist * 1.25, shift: 0, drop: KEYS[0].drop + 0.16, sensor: 0, size: KEYS[0].size, sats: 0 };
  // Ignition: uReveal runs from 0 to 1 over `ignite.ms` once `ignite()` is called.
  const ignition = { start: 0, ms: 0 };
  function ignite(ms) {
    if (reduceMotion) { fireUniforms.uReveal.value = 1; return; }
    ignition.start = performance.now(); ignition.ms = ms;
  }

  function frame(ts) {
    const t = ts / 1000, dt = Math.min(0.05, t - time); time = t;
    if (!reduceMotion) spinLon += dt * 1.4;                 // slow spin in the hero
    if (ignition.ms) {
      const k = clamp01((ts - ignition.start) / ignition.ms);
      fireUniforms.uReveal.value = k;
      if (k >= 1) ignition.ms = 0;
    }

    // Blend between the two keyframes on either side of the current scroll position
    const i = Math.min(KEYS.length - 2, Math.floor(stepF)), f = smooth(clamp01(stepF - i));
    const A = KEYS[i], B = KEYS[i + 1];
    const lonA = A.lon ?? spinLon, lonB = B.lon ?? spinLon;
    const small = isSmall();
    const target = {
      drop: small ? lerp(A.dropM, B.dropM, f) : lerp(A.drop, B.drop, f),
      lon: lerpAngle(lonA, lonB, f), lat: lerp(A.lat, B.lat, f), dist: lerp(A.dist, B.dist, f),
      shift: lerp(A.shift, B.shift, f), sensor: lerp(A.sensor, B.sensor, f), size: lerp(A.size, B.size, f), sats: lerp(A.sats, B.sats, f),
    };
    // ease toward the target so fast scrolling still looks smooth
    const k = 1 - Math.pow(0.0015, dt);
    cur.lon = lerpAngle(cur.lon, target.lon, k); cur.lat = lerp(cur.lat, target.lat, k);
    cur.dist = lerp(cur.dist, target.dist, k); cur.shift = lerp(cur.shift, target.shift, k); cur.drop = lerp(cur.drop, target.drop, k);
    cur.sensor = lerp(cur.sensor, target.sensor, k); cur.size = lerp(cur.size, target.size, k); cur.sats = lerp(cur.sats, target.sats, k);
    mouse.x += (mouse.tx - mouse.x) * 0.04; mouse.y += (mouse.ty - mouse.y) * 0.04;

    spin.rotation.y = THREE.MathUtils.degToRad(-cur.lon);
    tilt.rotation.x = THREE.MathUtils.degToRad(cur.lat);
    // Slide the picture (not the globe) so the globe sits below the headline in the hero, then
    // beside the text on wide screens or above it on phones. setViewOffset shifts the view without distorting it.
    const w = canvas.clientWidth, h = canvas.clientHeight;
    camera.setViewOffset(w, h, small ? 0 : -cur.shift * w, -cur.drop * h, w, h);
    camera.position.set(mouse.x * 0.25, -mouse.y * 0.18, small ? cur.dist * 1.3 : cur.dist);
    camera.lookAt(0, 0, 0);

    fireUniforms.uTime.value = t;
    fireUniforms.uSensorMix.value = cur.sensor;
    fireUniforms.uSize.value = cur.size;
    updateSats(t, cur.sats);

    composer.render();
    if (visible) raf = requestAnimationFrame(frame);
  }

  // Only render while the globe is on screen
  new IntersectionObserver(([e]) => {
    visible = e.isIntersecting && !document.hidden;
    if (visible && !raf) { time = performance.now() / 1000; raf = requestAnimationFrame(frame); }
    if (!visible) { cancelAnimationFrame(raf); raf = 0; }
  }).observe(canvas);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { visible = false; cancelAnimationFrame(raf); raf = 0; }
    else if (canvas.getBoundingClientRect().bottom > 0) { visible = true; time = performance.now() / 1000; if (!raf) raf = requestAnimationFrame(frame); }
  });

  time = performance.now() / 1000;
  raf = requestAnimationFrame(frame);
  onReady?.({ total: fires.n, ignite });
}
