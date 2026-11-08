//  DetectionMapView.swift
//  Wraps an AppKit MKMapView for SwiftUI, because it gives direct control over overlays and rendering.
//  This view handles map style, the detection overlay, the query-area outline, click-to-select,
//  the cursor coordinate readout, and zooming to the area.

import SwiftUI
import MapKit

struct DetectionMapView: NSViewRepresentable {
    let store: FireStore
    /// Reports the coordinate under the mouse pointer for the HUD readout.
    var onCursorMove: (CLLocationCoordinate2D?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> TrackingMapView {
        let map = TrackingMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsScale = true
        map.showsPitchControl = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)
        map.onMouseMove = { [weak map] point in
            guard let map else { return }
            onCursorMove(point.map { map.convert($0, toCoordinateFrom: map) })
        }
        context.coordinator.map = map
        return map
    }

    func updateNSView(_ map: TrackingMapView, context: Context) {
        let c = context.coordinator
        c.applyStyle(store.mapStyle, to: map)
        c.syncDetections(version: store.dataVersion, sensors: store.visibleSensors, detections: store.displayedDetections, on: map)
        c.syncAreaOutline(store.query.bounds, on: map)
        c.syncSelection(store.selected, on: map)
        if c.lastZoomRequest != store.zoomRequest {
            c.lastZoomRequest = store.zoomRequest
            map.setVisibleMapRect(store.query.bounds.mapRect,
                                  edgePadding: NSEdgeInsets(top: 60, left: 60, bottom: 90, right: 60),
                                  animated: c.hasZoomedOnce)
            c.hasZoomedOnce = true
        }
        if let f = store.focusRequest, f.id != c.lastFocusID {
            c.lastFocusID = f.id
            let span = min(map.region.span.latitudeDelta, 0.6)
            map.setRegion(MKCoordinateRegion(center: f.coordinate, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)), animated: true)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        let store: FireStore
        weak var map: MKMapView?
        var lastZoomRequest = -1
        var hasZoomedOnce = false
        var lastFocusID = 0

        private var detectionOverlay: DetectionOverlay?
        private var detectionKey: (Int, Set<Sensor>)?
        private var areaOverlay: MKPolygon?
        private var areaBounds: GeoBounds?
        private var selectionAnnotation: SelectionAnnotation?
        private var style: MapStyleChoice?

        init(store: FireStore) { self.store = store }

        /// Replaces the detection overlay only when the data or the sensor toggles change.
        func syncDetections(version: Int, sensors: Set<Sensor>, detections: [FireDetection], on map: MKMapView) {
            if let k = detectionKey, k.0 == version, k.1 == sensors { return }
            detectionKey = (version, sensors)
            let newOverlay = DetectionOverlay(detections: detections)
            map.addOverlay(newOverlay, level: .aboveLabels)
            if let old = detectionOverlay { map.removeOverlay(old) }
            detectionOverlay = newOverlay
        }

        /// Draws a dashed outline around the area that will be downloaded.
        func syncAreaOutline(_ bounds: GeoBounds, on map: MKMapView) {
            guard bounds != areaBounds else { return }
            areaBounds = bounds
            if let old = areaOverlay { map.removeOverlay(old) }
            guard bounds.validationError == nil else { areaOverlay = nil; return }
            var coords = [
                CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west),
                CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.east),
                CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east),
                CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.west),
            ]
            let poly = MKPolygon(coordinates: &coords, count: coords.count)
            map.addOverlay(poly, level: .aboveRoads)
            areaOverlay = poly
        }

        /// Shows a pulsing ring on the selected detection.
        func syncSelection(_ selected: FireDetection?, on map: MKMapView) {
            if selectionAnnotation?.detectionID == selected?.id { return }
            if let old = selectionAnnotation { map.removeAnnotation(old) }
            selectionAnnotation = nil
            guard let selected else { return }
            let a = SelectionAnnotation(detection: selected)
            map.addAnnotation(a)
            selectionAnnotation = a
        }

        func applyStyle(_ choice: MapStyleChoice, to map: MKMapView) {
            guard choice != style else { return }
            style = choice
            switch choice {
            case .satellite:
                let config = MKHybridMapConfiguration(elevationStyle: .flat)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            case .dark:
                let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            case .standard:
                let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
                config.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = config
            }
            map.appearance = NSAppearance(named: .darkAqua)
        }

        // MARK: Click to select

        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let map = g.view as? MKMapView, let overlay = detectionOverlay else { return }
            let pt = g.location(in: map)
            let mapPoint = MKMapPoint(map.convert(pt, toCoordinateFrom: map))
            let zoomScale = map.bounds.width / map.visibleMapRect.width
            let hits = overlay.hits(at: mapPoint, zoomScale: zoomScale)
            store.select(stack: hits)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let o = overlay as? DetectionOverlay { return DetectionRenderer(detectionOverlay: o) }
            if let p = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: p)
                r.strokeColor = NSColor(Theme.ember).withAlphaComponent(0.85)
                r.fillColor = NSColor(Theme.ember).withAlphaComponent(0.035)
                r.lineWidth = 1.5
                r.lineDashPattern = [6, 5]
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? SelectionAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: SelectionRingView.reuseID) as? SelectionRingView
                ?? SelectionRingView(annotation: a, reuseIdentifier: SelectionRingView.reuseID)
            view.annotation = a
            view.configure(sensor: a.sensor)
            return view
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            store.visibleMapBounds = GeoBounds(mapRect: mapView.visibleMapRect)
        }
    }
}

/// MKMapView subclass that reports where the mouse is, for the coordinate readout.
final class TrackingMapView: MKMapView {
    var onMouseMove: ((CGPoint?) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMove?(nil)
    }
}
