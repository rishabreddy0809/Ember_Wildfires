// globe.js: the web app's 3D Earth, like the Mac app's Globe view.
//
// • NASA Blue Marble by day, Black Marble city lights by night, with the real sun position, so
//   the day/night line is where it is right now.
// • One glowing ember per detection: MODIS orange, VIIRS light blue, bigger and brighter with
//   more fire power.
// • Drag to turn, scroll or pinch to zoom. Pointing at a fire rings it; clicking selects it.

import * as THREE from 'three';

const R = 1;                      // Earth radius
const MIN_DIST = 1.18, MAX_DIST = 6;
export const HOME_DIST = 4.3;
const REACH = 16;                 // how close (in CSS pixels) the pointer must be to a fire

export function createGlobe(canvas, { onHover, onPick, onMove } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
  renderer.setClearColor(0x000000, 0);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(32, 1, 0.01, 100);
  const loader = new THREE.TextureLoader();
  const tex = (url, srgb = true) => {
    const t = loader.load(url, () => { dirty = true; });
    if (srgb) t.colorSpace = THREE.SRGBColorSpace;
    t.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
    return t;
  };

  // ---------------------------------------------------------------- sun
  // Lit from above the viewer's left shoulder, like the Mac app, so the side you look at is
  // always in daylight with a sliver of night (and city lights) along the right edge.
  const sunDir = new THREE.Vector3(0, 0, 1);

  // ---------------------------------------------------------------- Earth
  const earthUniforms = {
    uDay: { value: tex('img/earth_day.jpg') },
    uNight: { value: tex('img/earth_night.jpg') },
    uSun: { value: sunDir },
  };
  const earth = new THREE.Mesh(new THREE.SphereGeometry(R, 160, 120), new THREE.ShaderMaterial({
    uniforms: earthUniforms,
    vertexShader: /* glsl */`
      varying vec2 vUv; varying vec3 vN; varying vec3 vView;
      void main(){ vUv = uv; vec4 w = modelMatrix * vec4(position, 1.); vN = normalize(w.xyz);
        vView = normalize(cameraPosition - w.xyz); gl_Position = projectionMatrix * viewMatrix * w; }`,
    fragmentShader: /* glsl */`
      uniform sampler2D uDay, uNight; uniform vec3 uSun;
      varying vec2 vUv; varying vec3 vN; varying vec3 vView;
      void main(){
        float ndl = dot(vN, uSun);
        float light = smoothstep(-0.12, 0.25, ndl);
        vec3 day = texture2D(uDay, vUv).rgb;
        day = pow(day, vec3(2.2)) * 0.95;                      // to linear
        vec3 lit = day * (0.05 + 1.1 * light);
        float dusk = exp(-(ndl * ndl) / 0.02);                 // warm light along the day/night line
        lit = mix(lit, lit * vec3(1.35, 0.72, 0.42), dusk * 0.5);
        float night = 1. - smoothstep(-0.18, 0.06, ndl);
        vec3 city = pow(texture2D(uNight, vUv).rgb, vec3(2.2)) * vec3(1.0, 0.78, 0.5) * 1.8 * night;
        float rim = pow(1. - max(dot(vN, vView), 0.), 3.);     // haze toward the edge
        vec3 col = lit + city + vec3(0.18, 0.42, 1.0) * rim * (0.08 + 0.6 * light);
        gl_FragColor = vec4(pow(col, vec3(1. / 2.2)), 1.);
      }`,
  }));
  // Longitude 0 must face +z to match toVec(): turn the texture seam to the back.
  earth.rotation.y = -Math.PI / 2;
  scene.add(earth);

  const cloudMat = new THREE.ShaderMaterial({
    transparent: true, depthWrite: false,
    uniforms: { uClouds: { value: tex('img/earth_clouds.jpg', false) }, uSun: { value: sunDir }, uOn: { value: 1 } },
    vertexShader: /* glsl */`varying vec2 vUv; varying vec3 vN; void main(){ vUv = uv; vN = normalize((modelMatrix * vec4(position, 1.)).xyz); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.); }`,
    fragmentShader: /* glsl */`
      uniform sampler2D uClouds; uniform vec3 uSun; uniform float uOn; varying vec2 vUv; varying vec3 vN;
      void main(){ float a = texture2D(uClouds, vUv).r; float l = smoothstep(-0.2, 0.3, dot(vN, uSun));
        gl_FragColor = vec4(vec3(0.95) * (0.08 + 0.92 * l), a * 0.62 * mix(0.25, 1., l) * uOn); }`,
  });
  const clouds = new THREE.Mesh(new THREE.SphereGeometry(R * 1.006, 120, 90), cloudMat);
  clouds.rotation.y = -Math.PI / 2;
  scene.add(clouds);

  // Atmosphere: a soft blue glow just outside the planet.
  scene.add(new THREE.Mesh(new THREE.SphereGeometry(R * 1.12, 96, 64), new THREE.ShaderMaterial({
    side: THREE.BackSide, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending,
    uniforms: { uSun: { value: sunDir } },
    vertexShader: /* glsl */`varying vec3 vN; varying vec3 vW; void main(){ vN = normalize(normalMatrix * normal); vW = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.); }`,
    fragmentShader: /* glsl */`uniform vec3 uSun; varying vec3 vN; varying vec3 vW;
      void main(){ float i = pow(clamp(0.78 - dot(vN, vec3(0., 0., 1.)), 0., 1.), 3.4);
        float l = 0.35 + 0.65 * smoothstep(-0.3, 0.4, dot(vW, uSun));
        gl_FragColor = vec4(vec3(0.25, 0.55, 1.0) * i * 1.4 * l, i); }`,
  })));

  // Stars
  {
    const n = 2600, p = new Float32Array(n * 3), v = new THREE.Vector3();
    for (let i = 0; i < n; i++) { v.randomDirection().multiplyScalar(30 + Math.random() * 30); p.set([v.x, v.y, v.z], i * 3); }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.BufferAttribute(p, 3));
    scene.add(new THREE.Points(g, new THREE.PointsMaterial({ color: 0x9aa8c8, size: 0.07, transparent: true, opacity: 0.6, depthWrite: false })));
  }

  // ---------------------------------------------------------------- fires
  const fireUniforms = { uTime: { value: 0 }, uScale: { value: 1 }, uBoost: { value: 1 }, uPR: { value: renderer.getPixelRatio() } };
  const fireMat = new THREE.ShaderMaterial({
    // Normal (not additive) blending: where thousands of fires overlap, they keep their own
    // orange or blue instead of adding up to white.
    uniforms: fireUniforms, transparent: true, depthWrite: false, blending: THREE.NormalBlending,
    vertexShader: /* glsl */`
      uniform float uTime, uScale, uBoost, uPR;
      attribute float aFrp, aSensor, aShow, aSeed;
      varying vec3 vColor; varying float vA; varying float vHot;
      void main(){
        vec4 mv = modelViewMatrix * vec4(position, 1.);
        vec3 n = normalize(position);
        float facing = dot(n, normalize(cameraPosition - position));
        vA = smoothstep(0.0, 0.18, facing) * aShow;
        float t = clamp(log(1. + aFrp) / log(10.) / 3., 0., 1.);      // log10(1 + FRP) / 3, as in the app
        // The Mac app's colours: MODIS orange, VIIRS light blue, hotter = lighter.
        vColor = aSensor < .5 ? vec3(1.5, 0.30 + 0.93 * t, 0.04 + 0.60 * t * t)
                              : vec3(0.13 + 0.40 * t * t, 0.42 + 0.29 * t, 0.8) * 1.35;
        vHot = t;
        float flicker = 0.88 + 0.12 * sin(uTime * (2.2 + aSeed * 3.) + aSeed * 50.);
        float size = (0.0060 + 0.0090 * t) * (aSensor < .5 ? 1.5 : 1.) * uBoost;   // in Earth radii
        gl_PointSize = aShow < .5 ? 0. : clamp(size * flicker * uScale / -mv.z, 1.4 * uPR, 64. * uPR);
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: /* glsl */`
      varying vec3 vColor; varying float vA; varying float vHot;
      void main(){
        float d = length(gl_PointCoord - .5) * 2.;
        float core = smoothstep(0.5, 0.12, d);
        float halo = exp(-d * d * 6.) * 0.45;
        float a = clamp(core + halo, 0., 1.) * vA;
        if (a < 0.01) discard;
        // Bright, saturated body; only strong fires get a white-hot centre.
        vec3 c = mix(vColor * 0.85, min(vColor, vec3(1.)), core) + vec3(1.0, 0.95, 0.85) * pow(core, 3.) * 0.55 * vHot;
        gl_FragColor = vec4(min(c, vec3(1.)), a);
      }`,
  });
  let fires = null, fireGeo = null, data = null, shown = null;

  function setData(f) {
    data = f;
    if (fires) { scene.remove(fires); fireGeo.dispose(); }
    const n = f.n, pos = new Float32Array(n * 3), aFrp = new Float32Array(n), aSensor = new Float32Array(n), aSeed = new Float32Array(n);
    const v = new THREE.Vector3();
    for (let i = 0; i < n; i++) {
      toVec(f.lat[i], f.lon[i], R * 1.0035, v); pos.set([v.x, v.y, v.z], i * 3);
      aFrp[i] = Number.isNaN(f.frp[i]) ? 0 : f.frp[i]; aSensor[i] = f.sensor[i]; aSeed[i] = Math.random();
    }
    fireGeo = new THREE.BufferGeometry();
    fireGeo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    fireGeo.setAttribute('aFrp', new THREE.BufferAttribute(aFrp, 1));
    fireGeo.setAttribute('aSensor', new THREE.BufferAttribute(aSensor, 1));
    fireGeo.setAttribute('aSeed', new THREE.BufferAttribute(aSeed, 1));
    fireGeo.setAttribute('aShow', new THREE.BufferAttribute(new Float32Array(n).fill(1), 1));
    fires = new THREE.Points(fireGeo, fireMat);
    fires.frustumCulled = false;
    fires.renderOrder = 3;
    scene.add(fires);
    setShown(() => true);
  }

  // Buckets of shown fires on a 1° grid, for finding the fire under the pointer.
  let buckets = new Map();
  function setShown(test) {
    if (!data) return;
    const a = fireGeo.attributes.aShow;
    buckets = new Map();
    shown = new Uint8Array(data.n);
    for (let i = 0; i < data.n; i++) {
      const s = test(i) ? 1 : 0;
      a.array[i] = s; shown[i] = s;
      if (!s) continue;
      const k = cellKey(Math.floor(data.lat[i]), Math.floor(data.lon[i]));
      let b = buckets.get(k); if (!b) buckets.set(k, (b = [])); b.push(i);
    }
    a.needsUpdate = true;
    if (hoverI >= 0 && !shown[hoverI]) setHover(-1);
    dirty = true;
  }
  const cellKey = (y, x) => (y + 90) * 400 + (((x % 360) + 540) % 360);

  // ---------------------------------------------------------------- rings (hover and selection)
  function makeRing(color, opacity) {
    const m = new THREE.Mesh(new THREE.RingGeometry(0.78, 1, 48), new THREE.MeshBasicMaterial({
      color, transparent: true, opacity, depthWrite: false, depthTest: false, side: THREE.DoubleSide,
    }));
    m.visible = false; m.renderOrder = 5; scene.add(m);
    return m;
  }
  const hoverRing = makeRing(0xffffff, 0.9);
  const pickRing = makeRing(0xffd9a8, 1);
  function placeRing(ring, i, px) {
    if (i < 0) { ring.visible = false; return; }
    const p = toVec(data.lat[i], data.lon[i], R * 1.004, new THREE.Vector3());
    ring.position.copy(p);
    ring.lookAt(p.clone().multiplyScalar(2));
    ring.userData.px = px;
    ring.visible = true;
  }

  // ---------------------------------------------------------------- camera
  const view = { lat: 12, lon: 15, dist: HOME_DIST };
  const target = { ...view };
  let spin = false, velLon = 0, velLat = 0;
  function flyTo(lat, lon, dist) {
    target.lat = clampLat(lat); target.lon = view.lon + wrap(lon - view.lon);
    if (dist !== undefined) target.dist = clamp(dist, MIN_DIST, MAX_DIST);
    velLon = velLat = 0;
    dirty = true;
  }

  // ---------------------------------------------------------------- input
  const pointers = new Map();
  let drag = null, pinch = null, moved = false, hoverI = -1, pickedI = -1, lastPointer = null;
  canvas.style.touchAction = 'none';
  canvas.addEventListener('pointerdown', (e) => {
    canvas.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 1) { drag = { x: e.clientX, y: e.clientY, t: performance.now() }; moved = false; velLon = velLat = 0; }
    if (pointers.size === 2) { const [a, b] = [...pointers.values()]; pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), dist: target.dist }; drag = null; moved = true; }
  });
  canvas.addEventListener('pointermove', (e) => {
    lastPointer = { x: e.clientX, y: e.clientY, type: e.pointerType };
    if (pointers.has(e.pointerId)) pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && pointers.size === 2) {
      const [a, b] = [...pointers.values()];
      target.dist = clamp(pinch.dist * pinch.d / Math.max(20, Math.hypot(a.x - b.x, a.y - b.y)), MIN_DIST, MAX_DIST);
      dirty = true; return;
    }
    if (drag) {
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) moved = true;
      if (moved) {
        const k = degPerPixel();
        const dLon = -dx * k, dLat = dy * k;
        target.lon += dLon; target.lat = clampLat(target.lat + dLat);
        view.lon = target.lon; view.lat = target.lat;
        const now = performance.now(), dt = Math.max(8, now - drag.t);
        velLon = dLon / dt * 16; velLat = dLat / dt * 16;
        drag = { x: e.clientX, y: e.clientY, t: now };
        canvas.classList.add('dragging');
        setHover(-1);
        dirty = true;
      }
      return;
    }
    hoverPending = true;
  });
  const end = (e) => {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) pinch = null;
    if (drag && !moved) {
      // The ringed fire if there is one (what the user is looking at), else the nearest.
      const i = e.pointerType === 'mouse' && hoverI >= 0 ? hoverI : findFire(e.clientX, e.clientY);
      select(i);
      onPick?.(i);
    }
    if (performance.now() - (drag?.t ?? 0) > 80) velLon = velLat = 0;   // let go after stopping: no glide
    drag = null;
    canvas.classList.remove('dragging');
  };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);
  canvas.addEventListener('pointerleave', () => { lastPointer = null; setHover(-1); });
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const k = Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.0016));
    target.dist = clamp(1 + (target.dist - 1) * k, MIN_DIST, MAX_DIST);
    dirty = true;
  }, { passive: false });

  let hoverPending = false;
  function setHover(i) {
    if (i === hoverI) return;
    hoverI = i;
    canvas.style.cursor = i >= 0 ? 'pointer' : '';
    dirty = true;
    if (i < 0) onHover?.(-1);
  }
  function select(i) { pickedI = i; dirty = true; }

  // Degrees of arc per CSS pixel at the point of the globe facing the camera.
  function degPerPixel() {
    const h = canvas.clientHeight || 1;
    return (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * (view.dist - R)) / h * 57.2958;
  }

  // The shown fire nearest the pointer, within REACH pixels, on the side facing us.
  const ray = new THREE.Raycaster(), ndc = new THREE.Vector2(), tmp = new THREE.Vector3(), camDir = new THREE.Vector3();
  function findFire(cx, cy) {
    if (!data) return -1;
    const r = canvas.getBoundingClientRect();
    const x = cx - r.left, y = cy - r.top;
    ndc.set((x / r.width) * 2 - 1, -(y / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    // Where the pointer meets the globe (or the closest point to it, near the edge).
    const o = ray.ray.origin, d = ray.ray.direction;
    const b = o.dot(d), c = o.lengthSq() - R * R, disc = b * b - c;
    const hit = disc >= 0 ? o.clone().addScaledVector(d, -b - Math.sqrt(disc)) : o.clone().addScaledVector(d, -b).setLength(R);
    const lat = Math.asin(clamp(hit.y / hit.length(), -1, 1)) * 57.2958;
    const lon = Math.atan2(hit.x, hit.z) * 57.2958;
    const tol = Math.max(REACH * degPerPixel() * 1.5, 0.05);
    const dy = Math.ceil(tol), dx = Math.min(180, Math.ceil(tol / Math.max(0.05, Math.cos(lat / 57.2958))));
    const cy0 = Math.floor(lat), cx0 = Math.floor(lon);
    camDir.copy(camera.position).normalize();
    let best = -1, bestD = REACH * REACH;
    for (let yy = cy0 - dy; yy <= cy0 + dy; yy++) {
      if (yy < -90 || yy > 89) continue;
      for (let xx = cx0 - dx; xx <= cx0 + dx; xx++) {
        const list = buckets.get(cellKey(yy, xx));
        if (!list) continue;
        for (const i of list) {
          toVec(data.lat[i], data.lon[i], R, tmp);
          if (tmp.dot(camDir) < 0.15) continue;
          tmp.project(camera);
          const sx = (tmp.x + 1) / 2 * r.width, sy = (1 - tmp.y) / 2 * r.height;
          const dd = (sx - x) ** 2 + (sy - y) ** 2;
          // Ties (fires on top of each other) go to the stronger fire.
          if (dd < bestD - 0.5 || (Math.abs(dd - bestD) <= 0.5 && (data.frp[i] || 0) > (data.frp[best] || 0))) { best = i; bestD = dd; }
        }
      }
    }
    return best;
  }

  /** Screen position (CSS px within the canvas) of a lat/lon, and whether it faces us. */
  function screenOf(lat, lon) {
    toVec(lat, lon, R, tmp);
    const facing = tmp.dot(camDir.copy(camera.position).normalize());
    tmp.project(camera);
    return { x: (tmp.x + 1) / 2 * canvas.clientWidth, y: (1 - tmp.y) / 2 * canvas.clientHeight, facing };
  }

  // ---------------------------------------------------------------- loop
  let dirty = true, last = performance.now(), raf = 0, running = true;
  function resize() {
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    fireUniforms.uScale.value = h * renderer.getPixelRatio() / (2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)));
    dirty = true;
  }
  new ResizeObserver(resize).observe(canvas);
  resize();

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const dt = Math.min(0.05, (now - last) / 1000); last = now;
    if (!drag) {
      if (Math.abs(velLon) + Math.abs(velLat) > 0.001) {   // glide after a flick
        target.lon += velLon; target.lat = clampLat(target.lat + velLat);
        velLon *= Math.pow(0.0025, dt); velLat *= Math.pow(0.0025, dt);
      } else if (spin) target.lon += dt * 4;
    }
    const k = 1 - Math.pow(0.0008, dt);
    const before = view.lat + view.lon + view.dist;
    view.lat += (target.lat - view.lat) * k;
    view.lon += (target.lon - view.lon) * k;
    view.dist += (target.dist - view.dist) * k;
    const moving = Math.abs(view.lat + view.lon + view.dist - before) > 1e-5;

    toVec(view.lat, view.lon, view.dist, camera.position);
    camera.up.set(0, 1, 0);
    camera.lookAt(0, 0, 0);
    camera.updateMatrixWorld();

    toVec(view.lat + 18, view.lon - 52, 1, sunDir);
    if (hoverPending && lastPointer && !drag) {
      hoverPending = false;
      const i = findFire(lastPointer.x, lastPointer.y);
      setHover(i);
      if (i >= 0) onHover?.(i, lastPointer.x, lastPointer.y);
    }
    // Rings stay the same size on screen.
    const ppx = degPerPixel() / 57.2958;
    for (const [ring, i, px] of [[hoverRing, hoverI !== pickedI ? hoverI : -1, 13], [pickRing, pickedI, 15]]) {
      placeRing(ring, i, px);
      if (i >= 0) ring.scale.setScalar(px * ppx * (1 + (ring === pickRing ? 0.12 * Math.sin(now / 260) : 0)));
    }
    if (hoverI >= 0 && moving && lastPointer) { const p = screenOf(data.lat[hoverI], data.lon[hoverI]); onHover?.(hoverI, p.x + canvas.getBoundingClientRect().left, p.y + canvas.getBoundingClientRect().top); }

    fireUniforms.uTime.value = now / 1000;
    renderer.render(scene, camera);
    onMove?.();
    dirty = false;
  }
  raf = requestAnimationFrame(frame);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { cancelAnimationFrame(raf); running = false; }
    else if (!running) { running = true; last = performance.now(); raf = requestAnimationFrame(frame); }
  });

  return {
    setData, setShown, flyTo, select, screenOf, findFire,
    get view() { return { ...view }; },
    setBoost(k) { fireUniforms.uBoost.value = k; },
    setClouds(on) { cloudMat.uniforms.uOn.value = on ? 1 : 0; clouds.visible = on; },
    setSpin(on) { spin = on; },
    zoom(f) { target.dist = clamp(1 + (target.dist - 1) * f, MIN_DIST, MAX_DIST); },
  };
}

// ---------------------------------------------------------------- helpers

/** Latitude/longitude (degrees) to a point; longitude 0 faces +z, north is +y. */
export function toVec(lat, lon, r, out) {
  const p = lat * Math.PI / 180, l = lon * Math.PI / 180;
  return out.set(r * Math.cos(p) * Math.sin(l), r * Math.sin(p), r * Math.cos(p) * Math.cos(l));
}
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const clampLat = (v) => clamp(v, -80, 80);
const wrap = (d) => ((((d + 180) % 360) + 360) % 360) - 180;
