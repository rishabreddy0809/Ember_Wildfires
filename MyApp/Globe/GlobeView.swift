//  GlobeView.swift
//  The 3D Earth with every displayed fire detection drawn on it.
//
//  All detections go into ONE mesh (a small square per detection, lying flat on the
//  surface), so a worldwide download of 100,000 points is a single draw call.
//  Nothing is clustered or merged: every detection has its own disc.
//
//  Drag to turn the globe, let go while moving to let it coast, scroll to zoom,
//  click a fire to select it, and double-click to turn back to the selection.

import SwiftUI
import SceneKit
import CoreLocation

struct GlobeView: NSViewRepresentable {
    let store: FireStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> SCNView {
        let v = GlobeSCNView(frame: .zero)
        let c = context.coordinator
        v.coordinator = c
        c.view = v
        v.backgroundColor = .black
        v.wantsLayer = true
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.scene = c.build()
        v.pointOfView = c.camera
        c.sync(animated: false)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        context.coordinator.sync(animated: true)
    }

    static func dismantleNSView(_ v: SCNView, coordinator: Coordinator) { coordinator.stop() }

    // MARK: - Mouse handling

    final class GlobeSCNView: SCNView {
        weak var coordinator: Coordinator?
        private var last: NSPoint?
        private var lastTime: TimeInterval = 0
        private var moved: CGFloat = 0
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }

        override func mouseMoved(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            coordinator?.pointer(x: p.x / max(bounds.width, 1) * 2 - 1, y: p.y / max(bounds.height, 1) * 2 - 1)
            // Over a fire the pointer becomes a hand, so it is plain that the fire can be clicked.
            let overFire = coordinator?.hover(p) ?? false
            (overFire ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        override func mouseExited(with e: NSEvent) {
            coordinator?.pointer(x: 0, y: 0)
            _ = coordinator?.hover(nil)
            NSCursor.arrow.set()
        }

        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { coordinator?.reset(); return }
            last = e.locationInWindow
            lastTime = e.timestamp
            moved = 0
            coordinator?.grab()
        }
        override func mouseDragged(with e: NSEvent) {
            guard let l = last else { return }
            let p = e.locationInWindow
            let dt = max(e.timestamp - lastTime, 1.0 / 240)
            moved += abs(p.x - l.x) + abs(p.y - l.y)
            if moved >= 4 { _ = coordinator?.hover(nil) }
            coordinator?.drag(dx: p.x - l.x, dy: p.y - l.y, dt: dt)
            last = p
            lastTime = e.timestamp
        }
        override func mouseUp(with e: NSEvent) {
            guard last != nil else { return }
            if moved < 4 { coordinator?.click(convert(e.locationInWindow, from: nil)) }
            coordinator?.release(flung: moved >= 4 && e.timestamp - lastTime < 0.08)
            last = nil
        }
        override func scrollWheel(with e: NSEvent) { coordinator?.scroll(e.scrollingDeltaY) }
        override func magnify(with e: NSEvent) { coordinator?.scroll(e.magnification * 220) }
    }

    /// The globe's orientation: where it is heading, where it is now, and how fast it
    /// is coasting after a fling.
    struct Spin {
        var targetX: Float = 0, targetY: Float = 0
        var x: Float = 0, y: Float = 0
        var velX: Float = 0, velY: Float = 0
        var held = false

        mutating func step(_ dt: Float, limit: Float) {
            if !held {
                targetX += velX * dt; targetY += velY * dt
                let damp = exp(-2.2 * dt)
                velX *= damp; velY *= damp
            }
            targetX = max(-limit, min(limit, targetX))
            // Ease toward the target; fast enough that dragging feels direct.
            let k = 1 - exp(-(held ? 40 : 6.5) * dt)
            x += (targetX - x) * k
            y += (targetY - y) * k
        }
    }

    // MARK: - Scene

    final class Coordinator {
        let store: FireStore
        weak var view: SCNView?
        let scene = SCNScene()
        let camera = SCNNode()

        private let earthPivot = SCNNode(), earthTilt = SCNNode(), earthSpin = SCNNode(), earth = SCNNode()
        private let clouds = SCNNode(), grid = SCNNode(), aurora = SCNNode()
        private let fires = SCNNode(), heat = SCNNode(), labels = SCNNode(), marker = SCNNode()
        private var markerRings: [SCNNode] = []
        private let hoverRing = SCNNode(), hoverTag = SCNNode()
        private var hovered: FireDetection?
        /// `-hover 12.5,20.1` on the command line rings the fire nearest that place, as if pointed at.
        private var pinnedHover: FireDetection?

        private var spin = Spin()
        // `-zoom 1` on the command line starts fully zoomed in.
        private var zoom: Double = max(-0.2, min(1, UserDefaults.standard.double(forKey: "zoom"))), zoomNow: Double = 0
        private var pointerX: CGFloat = 0, pointerY: CGFloat = 0, camX: CGFloat = 0, camY: CGFloat = 0
        private var gridNow: Float = 0, auroraNow: Float = 0, pulseNow: Float = 0
        private var timer: Timer?
        private var lastTick = CACurrentMediaTime()

        private var fx = SceneFX()
        private var meshKey: FireStore.DisplayKey?
        private var meshGeneration = 0
        private var labelSignature = ""
        private var markerID: UUID?
        private var pingRegion: String?
        private var lastRegionFocus = 0
        private var lastFocus = 0
        private var hasFacedData = false
        private var active = false

        static let radius: CGFloat = 1.24
        static let center = SCNVector3(0.16, -0.02, 0)
        static let cameraDistance: CGFloat = 5.6

        init(store: FireStore) { self.store = store }

        func build() -> SCNScene {
            scene.background.contents = Bodies.image("stars")
            scene.background.intensity = 0.9

            let surface = SCNSphere(radius: 1); surface.segmentCount = 160
            surface.firstMaterial = Bodies.earthMaterial()
            earth.geometry = surface
            let cloudShell = SCNSphere(radius: 1.007); cloudShell.segmentCount = 120
            cloudShell.firstMaterial = Bodies.cloudMaterial()
            clouds.geometry = cloudShell
            clouds.renderingOrder = 5
            clouds.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 1400)))
            let gridShell = SCNSphere(radius: 1.01); gridShell.segmentCount = 120
            gridShell.firstMaterial = Bodies.gridMaterial(tint: NSColor(Theme.onDark))
            grid.geometry = gridShell
            grid.renderingOrder = 6
            let auroraShell = SCNSphere(radius: 1.03); auroraShell.segmentCount = 120
            auroraShell.firstMaterial = Bodies.auroraMaterial()
            aurora.geometry = auroraShell
            aurora.renderingOrder = 7
            let heatShell = SCNSphere(radius: 1.003); heatShell.segmentCount = 160
            heatShell.firstMaterial = Bodies.heatMaterial()
            heat.geometry = heatShell
            heat.renderingOrder = 8
            heat.isHidden = true
            fires.renderingOrder = 9
            marker.renderingOrder = 10
            marker.isHidden = true
            labels.renderingOrder = 20
            for n in [heat, fires, marker, labels] { earth.addChildNode(n) }
            for n in [earth, clouds, grid, aurora] { earthSpin.addChildNode(n) }
            earthTilt.addChildNode(earthSpin)
            earthPivot.addChildNode(earthTilt)

            let inner = SCNSphere(radius: 1.012); inner.segmentCount = 120
            inner.firstMaterial = Bodies.innerAtmosphere()
            let innerNode = SCNNode(geometry: inner); innerNode.renderingOrder = 10
            let outer = SCNSphere(radius: 1.16); outer.segmentCount = 120
            outer.firstMaterial = Bodies.outerAtmosphere(shellRatio: 1.16)
            let outerNode = SCNNode(geometry: outer); outerNode.renderingOrder = 11
            earthPivot.addChildNode(innerNode)
            earthPivot.addChildNode(outerNode)
            earthPivot.position = Self.center
            earthPivot.scale = SCNVector3(Self.radius, Self.radius, Self.radius)
            scene.rootNode.addChildNode(earthPivot)

            // The ring that marks the selected detection: one steady, one that spreads.
            for _ in 0..<2 {
                let ring = SCNNode(geometry: SCNTube(innerRadius: 0.0105, outerRadius: 0.0122, height: 0.0004))
                ring.geometry?.firstMaterial = Bodies.glow(.white, additive: false)
                ring.renderingOrder = 9
                marker.addChildNode(ring)
                markerRings.append(ring)
            }

            // What the pointer is over: a ring around the fire and a tag saying what it is.
            let halo = SCNNode(geometry: SCNTube(innerRadius: 0.0150, outerRadius: 0.0176, height: 0.0004))
            halo.geometry?.firstMaterial = Bodies.glow(.white, additive: false)
            halo.geometry?.firstMaterial?.readsFromDepthBuffer = false
            hoverRing.addChildNode(halo)
            hoverRing.renderingOrder = 11
            hoverRing.isHidden = true
            hoverTag.renderingOrder = 21
            hoverTag.isHidden = true
            hoverTag.constraints = [SCNBillboardConstraint()]
            earth.addChildNode(hoverRing)
            earth.addChildNode(hoverTag)

            camera.camera = Bodies.camera(fov: 32)
            camera.position = SCNVector3(0, 0, Self.cameraDistance)
            scene.rootNode.addChildNode(camera)

            scene.rootNode.addChildNode(Bodies.sunLight())
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient
            ambient.light!.intensity = 18
            ambient.light!.color = NSColor(calibratedRed: 0.5, green: 0.65, blue: 1, alpha: 1)
            scene.rootNode.addChildNode(ambient)
            return scene
        }

        // MARK: Keeping up with the store

        /// Called whenever something the globe shows may have changed.
        func sync(animated: Bool) {
            // Render only while the Globe view is the one on screen.
            let shouldRun = store.mode == .globe
            if shouldRun != active {
                active = shouldRun
                view?.isPlaying = shouldRun
                if shouldRun { start() } else { stop() }
            }

            if pinnedHover == nil, !store.displayedDetections.isEmpty,
               let parts = UserDefaults.standard.string(forKey: "hover")?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2,
               let d = store.nearest(latitude: parts[0], longitude: parts[1], tolerance: 3) {
                pinnedHover = d
                _ = hover(nil)
            }

            let key = store.displayKey
            if key != meshKey {
                meshKey = key
                rebuildFires(store.displayedDetections)
            }

            let top = Self.spreadOut(store.regions)
            let signature = top.map { "\($0.id):\($0.count)" }.joined(separator: "|")
            if signature != labelSignature {
                labelSignature = signature
                rebuildLabels(top)
            }

            let selected = store.selected
            if selected?.id != markerID {
                markerID = selected?.id
                if let d = selected {
                    place(marker, latitude: d.latitude, longitude: d.longitude, radius: 1.006)
                    marker.isHidden = false
                } else {
                    marker.isHidden = true
                }
            }

            let region = store.selectedRegion
            if region?.id != pingRegion {
                pingRegion = region?.id
                if let region {
                    earth.geometry?.firstMaterial?.setValue(
                        NSValue(scnVector3: sphereVector(lat: region.latitude, lon: region.longitude)), forKey: "pingDir")
                }
            }

            if store.fx != fx {
                fx = store.fx
                clouds.runAction(.fadeOpacity(to: fx.clouds ? 1 : 0.001, duration: 0.5))
            }

            if let f = store.regionFocus, f.id != lastRegionFocus {
                lastRegionFocus = f.id
                face(latitude: f.region.latitude, longitude: f.region.longitude, animated: animated && hasFacedData)
                hasFacedData = true
            }
            if let f = store.focusRequest, f.id != lastFocus {
                lastFocus = f.id
                face(latitude: f.coordinate.latitude, longitude: f.coordinate.longitude, animated: animated && hasFacedData)
                hasFacedData = true
            }
            // The first time data arrives, turn to wherever most of it is.
            if !hasFacedData, let busiest = store.regions.first {
                hasFacedData = true
                face(latitude: busiest.latitude, longitude: busiest.longitude, animated: false)
            }
        }

        /// Turns the globe so a coordinate faces the camera.
        private func face(latitude: Double, longitude: Double, animated: Bool) {
            spin.velX = 0; spin.velY = 0
            spin.targetX = Float(latitude * .pi / 180) * 0.8
            spin.targetY = shortest(Float(-longitude * .pi / 180), from: spin.y)
            if !animated { spin.x = spin.targetX; spin.y = spin.targetY }
        }

        private func shortest(_ a: Float, from current: Float) -> Float {
            var v = a
            while v - current > .pi { v -= 2 * .pi }
            while v - current < -.pi { v += 2 * .pi }
            return v
        }

        /// Puts a node on the surface with its Y axis pointing straight up from the ground.
        private func place(_ node: SCNNode, latitude: Double, longitude: Double, radius: Double) {
            let p = sphereVector(lat: latitude, lon: longitude, radius: radius)
            node.position = p
            let up = SCNVector3(0, 1, 0), normal = p.normalized
            let axis = up.cross(normal)
            let cosine = max(-1, min(1, normal.y))
            node.rotation = axis.length < 1e-6 ? SCNVector4(1, 0, 0, cosine > 0 ? 0 : CGFloat.pi)
                                               : SCNVector4(axis.x, axis.y, axis.z, acos(cosine))
        }

        // MARK: Fires

        private var heatNow: Float = 1

        private func rebuildFires(_ detections: [FireDetection]) {
            meshGeneration += 1
            let generation = meshGeneration
            guard !detections.isEmpty else { fires.geometry = nil; heat.isHidden = true; return }
            Task {
                async let heatPixels = HeatMap.build(detections)
                let mesh = await FireMesh.build(detections)
                let pixels = await heatPixels
                guard generation == self.meshGeneration else { return }   // a newer request has replaced this one
                if let image = HeatMap.image(pixels) {
                    self.heat.geometry?.firstMaterial?.diffuse.contents = image
                    self.heat.isHidden = false
                }
                let vertices = mesh.count * 4
                let position = SCNGeometrySource(data: mesh.positions, semantic: .vertex, vectorCount: vertices,
                                                 usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                                 dataOffset: 0, dataStride: 12)
                let color = SCNGeometrySource(data: mesh.colors, semantic: .color, vectorCount: vertices,
                                              usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                                              dataOffset: 0, dataStride: 16)
                let uv = SCNGeometrySource(data: mesh.uvs, semantic: .texcoord, vectorCount: vertices,
                                           usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
                                           dataOffset: 0, dataStride: 8)
                let element = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles,
                                                 primitiveCount: mesh.count * 2, bytesPerIndex: 4)
                // The centre of each square, in the normal slot (see Bodies.fireMaterial).
                let center = SCNGeometrySource(data: mesh.centers, semantic: .normal, vectorCount: vertices,
                                               usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                               dataOffset: 0, dataStride: 12)
                let geometry = SCNGeometry(sources: [position, center, color, uv], elements: [element])
                geometry.firstMaterial = Bodies.fireMaterial()
                self.fires.geometry = geometry
            }
        }

        // MARK: Labels

        /// Up to five of the busiest regions whose tags will not sit on top of each other.
        private static func spreadOut(_ regions: [RegionSummary]) -> [RegionSummary] {
            var kept: [RegionSummary] = []
            for r in regions.prefix(12) where kept.count < 5 {
                let a = sphereVector(lat: r.latitude, lon: r.longitude)
                let clear = kept.allSatisfy { k in
                    let b = sphereVector(lat: k.latitude, lon: k.longitude)
                    return a.x * b.x + a.y * b.y + a.z * b.z < 0.9      // more than about 26° apart
                }
                if clear { kept.append(r) }
            }
            return kept
        }

        /// A paper tag on each of the busiest regions.
        private func rebuildLabels(_ regions: [RegionSummary]) {
            labels.childNodes.forEach { $0.removeFromParentNode() }
            for r in regions {
                let (image, aspect) = Bodies.label(r.name, value: r.count.grouped, dot: NSColor(r.activity.color))
                let height: CGFloat = 0.05
                let plane = SCNPlane(width: height * aspect, height: height)
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = image
                m.readsFromDepthBuffer = false
                m.writesToDepthBuffer = false
                plane.firstMaterial = m
                let tag = SCNNode(geometry: plane)
                tag.name = "label"
                tag.renderingOrder = 20
                tag.pivot = SCNMatrix4MakeTranslation(-(height * aspect / 2 + 0.018), 0, 0)   // sit to the right of the point
                let anchor = SCNNode()
                anchor.name = "region:" + r.id
                anchor.position = sphereVector(lat: r.latitude, lon: r.longitude, radius: 1.03)
                anchor.constraints = [SCNBillboardConstraint()]
                anchor.addChildNode(tag)
                labels.addChildNode(anchor)
            }
        }

        /// Labels ignore depth so the limb never slices them; instead they are hidden
        /// whenever their anchor turns onto the far side.
        private func updateLabels(scale: CGFloat) {
            for anchor in labels.childNodes {
                anchor.scale = SCNVector3(scale, scale, scale)
                let facing = (anchor.worldPosition - Self.center).normalized.z
                // Hide rather than fade to zero: SceneKit complains about fully transparent nodes.
                let a = max(0, min(1, (facing - 0.34) * 7))
                anchor.isHidden = a < 0.02
                anchor.opacity = max(a, 0.02)
            }
        }

        // MARK: Frame loop

        func start() {
            guard timer == nil else { return }
            lastTick = CACurrentMediaTime()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)   // keeps running while the mouse is down
            timer = t
        }

        func stop() { timer?.invalidate(); timer = nil }

        private func tick() {
            let now = CACurrentMediaTime()
            let dt = Float(min(now - lastTick, 0.05))
            lastTick = now

            if fx.spin, !spin.held { spin.targetY += 0.05 * dt }
            spin.step(dt, limit: 1.4)

            let ease = CGFloat(1 - exp(-4 * dt))
            camX += (pointerX * 0.10 - camX) * ease
            camY += (pointerY * 0.06 - camY) * ease
            zoomNow += (zoom - zoomNow) * Double(1 - exp(-8 * dt))

            let fade = 1 - exp(-5 * dt)
            gridNow += ((fx.grid ? 1 : 0) - gridNow) * fade
            auroraNow += ((fx.aurora ? 1 : 0) - auroraNow) * fade
            pulseNow += ((fx.pulse && pingRegion != nil ? 1 : 0) - pulseNow) * fade

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            earthTilt.eulerAngles.x = CGFloat(spin.x)
            earthSpin.eulerAngles.y = CGFloat(spin.y)
            // The camera slides toward the globe as it zooms, and drifts a little with the pointer.
            let z = CGFloat(zoomNow)
            camera.position = SCNVector3(camX * (1 - 0.7 * z) + Self.center.x * z,
                                         camY * (1 - 0.7 * z) + Self.center.y * z,
                                         Self.cameraDistance - 3.0 * z)
            grid.geometry?.firstMaterial?.setValue(NSNumber(value: gridNow * 0.5), forKey: "amount")
            aurora.geometry?.firstMaterial?.setValue(NSNumber(value: auroraNow), forKey: "amount")
            earth.geometry?.firstMaterial?.setValue(NSNumber(value: pulseNow), forKey: "pingOn")
            // Embers, labels and the selection ring hold their on-screen size as the camera moves in.
            let hold = Float(1 / (1 + 2.4 * max(0, zoomNow)))
            // Close up, the soft heat glow steps back and the individual sparks carry the picture.
            let near = Float(max(0, zoomNow))
            fires.geometry?.firstMaterial?.setValue(NSNumber(value: 1 / (1 + 0.45 * near)), forKey: "emberScale")
            fires.geometry?.firstMaterial?.setValue(NSNumber(value: Float(now.truncatingRemainder(dividingBy: 3600))), forKey: "emberTime")
            heatNow += (max(0.3, 1 - 1.2 * near) - heatNow) * fade
            heat.geometry?.firstMaterial?.setValue(NSNumber(value: heatNow), forKey: "heatAmount")
            marker.scale = SCNVector3(CGFloat(hold), 1, CGFloat(hold))
            if !hoverRing.isHidden {
                let breathe = CGFloat(hold) * (1 + 0.10 * CGFloat(sin(now * 5)))
                hoverRing.scale = SCNVector3(breathe, 1, breathe)
                hoverTag.scale = SCNVector3(CGFloat(hold), CGFloat(hold), CGFloat(hold))
            }
            updateLabels(scale: CGFloat(hold))
            if !marker.isHidden, let pulse = markerRings.last {
                let u = CGFloat((now / 1.6).truncatingRemainder(dividingBy: 1))
                let s = 1 + 1.6 * u
                pulse.scale = SCNVector3(s, 1, s)
                pulse.opacity = max(0.02, 1 - u)
            }
            SCNTransaction.commit()
        }

        // MARK: Interaction

        func pointer(x: CGFloat, y: CGFloat) { pointerX = x; pointerY = y }

        func grab() { spin.held = true; spin.velX = 0; spin.velY = 0 }

        func drag(dx: CGFloat, dy: CGFloat, dt: TimeInterval) {
            // Turn less per point of travel when zoomed in, so the ground follows the pointer.
            let k = Float(0.0046 * (1 - 0.72 * max(0, zoomNow)))
            let ax = -Float(dy) * k, ay = Float(dx) * k
            spin.targetX += ax; spin.targetY += ay
            spin.velX = spin.velX * 0.5 + ax / Float(dt) * 0.5
            spin.velY = spin.velY * 0.5 + ay / Float(dt) * 0.5
        }

        /// Let go. If the hand was still moving the globe keeps coasting; otherwise it stops.
        func release(flung: Bool) {
            if !flung { spin.velX = 0; spin.velY = 0 }
            let cap: Float = 6
            spin.velX = max(-cap, min(cap, spin.velX)); spin.velY = max(-cap, min(cap, spin.velY))
            spin.held = false
        }

        func scroll(_ dy: CGFloat) { zoom = max(-0.2, min(1, zoom + Double(dy) * 0.004)) }

        /// Double-click: undo the zoom and turn back to the selection.
        func reset() {
            zoom = 0
            if let d = store.selected {
                face(latitude: d.latitude, longitude: d.longitude, animated: true)
            } else if let r = store.selectedRegion ?? store.regions.first {
                face(latitude: r.latitude, longitude: r.longitude, animated: true)
            }
        }

        /// How far from a fire, in screen points, the pointer may be and still count as on it.
        /// Generous on purpose: nobody should have to hit a few-pixel dot exactly.
        private static let reach: Double = 16

        /// Where on the Earth a point of the view lands, and how many degrees `reach` covers there.
        private func ground(at p: CGPoint) -> (latitude: Double, longitude: Double, tolerance: Double)? {
            guard let view else { return nil }
            let hits = view.hitTest(p, options: [.rootNode: earthSpin, .searchMode: SCNHitTestSearchMode.all.rawValue,
                                                 .ignoreHiddenNodes: false])
            guard let hit = hits.filter({ $0.node === earth }).max(by: { $0.worldCoordinates.z < $1.worldCoordinates.z }) else { return nil }
            let l = hit.localCoordinates.normalized
            let latitude = Double(asin(max(-1, min(1, l.y)))) * 180 / .pi
            let longitude = Double(atan2(l.x, l.z)) * 180 / .pi
            // The globe's radius on screen is roughly the points per radian near the middle.
            // Zoomed in the camera is closer, so measure against the near surface instead.
            let near = view.projectPoint(Self.center + SCNVector3(0, 0, Self.radius))
            let side = view.projectPoint(Self.center + SCNVector3(Self.radius * 0.1, 0, Self.radius * 0.995))
            let pointsPerRadian = max(60, abs(side.x - near.x) / 0.1)
            return (latitude, longitude, max(0.05, Self.reach / Double(pointsPerRadian) * 180 / .pi))
        }

        /// The pointer moved (or left, with nil). Rings the nearest fire within reach and
        /// tags it with its sensor and power. Returns whether a fire is under the pointer.
        func hover(_ p: CGPoint?) -> Bool {
            var found: FireDetection?
            if let p, !spin.held, let g = ground(at: p) {
                found = store.nearest(latitude: g.latitude, longitude: g.longitude, tolerance: g.tolerance)
            }
            if p == nil, let pinned = pinnedHover { found = pinned }
            guard found?.id != hovered?.id else { return found != nil }
            hovered = found
            guard let d = found else {
                hoverRing.isHidden = true
                hoverTag.isHidden = true
                return false
            }
            place(hoverRing, latitude: d.latitude, longitude: d.longitude, radius: 1.0065)
            hoverRing.isHidden = false

            let dot = d.sensor == .modis ? NSColor(Theme.modis) : NSColor(Theme.viirs)
            let (image, aspect) = Bodies.label(d.sensor == .modis ? "MODIS" : "VIIRS", value: megawatts(d.frp) + "  ·  click for details", dot: dot)
            let height: CGFloat = 0.05
            let plane = SCNPlane(width: height * aspect, height: height)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = image
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            plane.firstMaterial = m
            hoverTag.geometry = plane
            hoverTag.pivot = SCNMatrix4MakeTranslation(-(height * aspect / 2 + 0.03), -0.045, 0)   // up and to the right of the ring
            hoverTag.position = sphereVector(lat: d.latitude, lon: d.longitude, radius: 1.03)
            hoverTag.isHidden = false
            return true
        }

        /// A click: select the fire under the pointer, or failing that the region clicked.
        func click(_ p: CGPoint) {
            guard let g = ground(at: p) else {
                store.clearSelection()
                return
            }
            // Pick around the ringed fire when there is one, so the click selects exactly what was ringed.
            if let d = hovered {
                store.pick(latitude: d.latitude, longitude: d.longitude, tolerance: g.tolerance)
            } else {
                store.pick(latitude: g.latitude, longitude: g.longitude, tolerance: g.tolerance)
            }
        }
    }
}

// MARK: - Heat map

/// A picture of the whole Earth (longitude across, latitude down) showing how much fire
/// there is at each place. It is wrapped around the globe under the sparks.
nonisolated enum HeatMap {
    static let width = 4096, height = 2048

    /// Premultiplied RGBA pixels. Built off the main thread.
    @concurrent
    static func build(_ detections: [FireDetection]) async -> Data {
        let w = width, h = height
        var field = [Float](repeating: 0, count: w * h)   // all fire
        var cool = [Float](repeating: 0, count: w * h)    // the VIIRS part of it
        // Drop each detection onto the grid, split between the four nearest pixels.
        // Stronger fires count for more, on a log scale.
        for d in detections {
            let x = (d.longitude + 180) / 360 * Double(w) - 0.5
            let y = (90 - d.latitude) / 180 * Double(h) - 0.5
            guard x.isFinite, y.isFinite else { continue }
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let weight = Float(0.5 + 0.5 * log10(1 + min(max(d.frp ?? 0, 0), 3000)))
            for (dx, dy, k) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                let py = y0 + dy
                guard py >= 0, py < h else { continue }
                let at = py * w + ((x0 + dx) % w + w) % w
                field[at] += weight * k
                if d.sensor == .viirs { cool[at] += weight * k }
            }
        }

        // Soften it. Three box blurs make a smooth round falloff. Rows near the poles are
        // blurred wider, because a pixel there covers less ground east to west.
        var scratch = [Float](repeating: 0, count: w * h)
        func soften(_ field: inout [Float]) {
            for _ in 0..<3 {
                for y in 0..<h {
                    let latitude = (0.5 - (Double(y) + 0.5) / Double(h)) * Double.pi
                    let r = min(24, max(2, Int((2 / max(0.08, cos(latitude))).rounded())))
                    let scale = 1 / Float(2 * r + 1), row = y * w
                    var sum: Float = 0
                    for x in -r...r { sum += field[row + (x + w) % w] }
                    for x in 0..<w {
                        scratch[row + x] = sum * scale
                        sum += field[row + (x + r + 1) % w] - field[row + (x - r + w) % w]
                    }
                }
                let r = 2, scale = 1 / Float(2 * r + 1)
                for x in 0..<w {
                    var sum: Float = 0
                    for y in -r...r { sum += scratch[min(h - 1, max(0, y)) * w + x] }
                    for y in 0..<h {
                        field[y * w + x] = sum * scale
                        sum += scratch[min(h - 1, y + r + 1) * w + x] - scratch[max(0, y - r) * w + x]
                    }
                }
            }
        }
        soften(&field)
        soften(&cool)

        // Colour it by how much fire there is: nothing, then a deep colour, then brighter, then
        // near white. Where MODIS saw the fire the colours are warm; where VIIRS did they are blue.
        typealias Stop = (at: Float, r: Float, g: Float, b: Float)
        let warm: [Stop] = [(0.00, 0.55, 0.03, 0.00), (0.35, 0.95, 0.16, 0.02), (0.62, 1.00, 0.44, 0.04),
                            (0.84, 1.00, 0.70, 0.18), (1.00, 1.00, 0.86, 0.48)]
        let cold: [Stop] = [(0.00, 0.02, 0.10, 0.55), (0.35, 0.05, 0.30, 0.95), (0.62, 0.16, 0.56, 1.00),
                            (0.84, 0.42, 0.78, 1.00), (1.00, 0.72, 0.92, 1.00)]
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where field[i] > 0.0008 {
            let v = min(1, log2(1 + field[i] * 40) / 8)
            var k = 1
            while k < warm.count - 1 && v > warm[k].at { k += 1 }
            let t = (v - warm[k - 1].at) / (warm[k].at - warm[k - 1].at)
            let part = min(1, max(0, cool[i] / field[i]))    // how much of the fire here is VIIRS
            let share = part * part * part                   // lean warm, so MODIS shows wherever it saw fire
            func channel(_ c: KeyPath<Stop, Float>) -> Float {
                let hot = warm[k - 1][keyPath: c] + (warm[k][keyPath: c] - warm[k - 1][keyPath: c]) * t
                let blue = cold[k - 1][keyPath: c] + (cold[k][keyPath: c] - cold[k - 1][keyPath: c]) * t
                return hot + (blue - hot) * share
            }
            let alpha = min(0.82, pow(v, 0.75) * 1.05)
            pixels[i * 4] = UInt8(channel(\.r) * alpha * 255)
            pixels[i * 4 + 1] = UInt8(channel(\.g) * alpha * 255)
            pixels[i * 4 + 2] = UInt8(channel(\.b) * alpha * 255)
            pixels[i * 4 + 3] = UInt8(alpha * 255)
        }
        return Data(pixels)
    }

    static func image(_ pixels: Data) -> CGImage? {
        guard pixels.count == width * height * 4, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Fire mesh

/// The vertex data for every detection, ready to hand to SceneKit.
nonisolated struct FireMesh: Sendable {
    let positions: Data
    let centers: Data
    let colors: Data
    let uvs: Data
    let indices: Data
    let count: Int

    /// Half the width of a detection's square, as a fraction of the Earth's radius.
    /// It grows with the log of fire radiative power, like the markers on the map.
    static func halfSize(frp: Double?) -> Float {
        Float(0.0040 + 0.0032 * log10(1 + min(max(frp ?? 0, 0), 3000)))
    }

    /// Ember colour. The sensor sets the hue: MODIS burns orange, VIIRS burns light blue.
    /// Fire radiative power sets how hot it looks, on a log scale: the faintest are deep
    /// and saturated, the strongest (1,000 MW and up) are pale and bright.
    static func color(frp: Double?, sensor: Sensor) -> (Float, Float, Float) {
        let t = Float(min(1, log10(1 + max(frp ?? 0, 0)) / 3))
        switch sensor {
        // MODIS detections are far fewer (about one in seven), so they are drawn brighter
        // to hold their own among the blue.
        case .modis: return (1.5, 0.30 + 0.93 * t, 0.04 + 0.60 * t * t)
        case .viirs: return (0.13 + 0.40 * t * t, 0.42 + 0.29 * t, 0.8)
        }
    }

    /// Builds the mesh off the main thread. Detections go in from weakest to strongest,
    /// so the strongest fires are drawn last and are never hidden under weaker ones.
    @concurrent
    static func build(_ detections: [FireDetection]) async -> FireMesh {
        let n = detections.count
        var positions = [Float](); positions.reserveCapacity(n * 12)
        var centers = [Float](); centers.reserveCapacity(n * 12)
        var colors = [Float](); colors.reserveCapacity(n * 16)
        var uvs = [Float](); uvs.reserveCapacity(n * 8)
        var indices = [UInt32](); indices.reserveCapacity(n * 6)
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        var quad: UInt32 = 0

        for d in detections.sorted(by: { ($0.frp ?? 0) < ($1.frp ?? 0) }) {
            let rgb = color(frp: d.frp, sensor: d.sensor)
            let phi = Float(d.latitude * .pi / 180), lam = Float(d.longitude * .pi / 180)
            let cp = cos(phi), sp = sin(phi), cl = cos(lam), sl = sin(lam)
            let c = SIMD3<Float>(cp * sl, sp, cp * cl) * 1.0045
            let east = SIMD3<Float>(cl, 0, -sl)
            let north = SIMD3<Float>(-sp * sl, cp, -sp * cl)
            // A MODIS pixel is 1 km across against 375 m for VIIRS, so its ember is drawn larger.
            let s = halfSize(frp: d.frp) * (d.sensor == .modis ? 1.5 : 1)
            for (u, v) in corners {
                let p = c + east * (u * s) + north * (v * s)
                positions.append(p.x); positions.append(p.y); positions.append(p.z)
                centers.append(c.x); centers.append(c.y); centers.append(c.z)
                colors.append(rgb.0); colors.append(rgb.1); colors.append(rgb.2); colors.append(1)
                // The second coordinate also carries a per-ember number, 0 to 15, in steps of two.
                uvs.append((u + 1) / 2); uvs.append((v + 1) / 2 + Float(quad % 16) * 2)
            }
            let base = quad * 4
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            quad += 1
        }

        func data<T>(_ a: [T]) -> Data { a.withUnsafeBufferPointer { Data(buffer: $0) } }
        return FireMesh(positions: data(positions), centers: data(centers), colors: data(colors), uvs: data(uvs), indices: data(indices), count: Int(quad))
    }
}
