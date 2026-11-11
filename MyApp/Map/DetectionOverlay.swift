//  DetectionOverlay.swift
//  Draws thousands of detections on the map quickly.
//
//  Giving every point its own SwiftUI annotation view gets slow after a few hundred points.
//  Instead, all detections go into ONE MapKit overlay, and a custom renderer draws them
//  with Core Graphics. MapKit renders the overlay in tiles on background threads, so
//  panning stays smooth even with tens of thousands of points.
//
//  Every detection is drawn separately. Nothing is clustered or merged, so overlapping
//  detections stay visible as overlapping points.

import MapKit
import AppKit

/// Sensor colors for Core Graphics drawing. They must match Theme.modis and Theme.viirs in Theme.swift.
nonisolated enum SensorPalette {
    static func cgColor(_ s: Sensor, alpha: CGFloat = 1) -> CGColor {
        switch s {
        case .modis: CGColor(srgbRed: 1.00, green: 0.63, blue: 0.20, alpha: alpha)  // amber
        case .viirs: CGColor(srgbRed: 0.27, green: 0.76, blue: 1.00, alpha: alpha)  // sky blue
        }
    }

    /// Marker radius in screen points. It grows with the log of fire radiative power,
    /// so a 1,000 MW fire is visibly larger than a 1 MW one but doesn't cover the map.
    static func radius(frp: Double?) -> CGFloat {
        let f = max(0, frp ?? 0)
        return CGFloat(min(11, max(3, 3 + 2.3 * log10(1 + f))))
    }
}

/// One overlay that holds every visible detection.
nonisolated final class DetectionOverlay: NSObject, MKOverlay, @unchecked Sendable {

    /// The pre-computed drawing data for one detection.
    struct Item: Sendable {
        let point: MKMapPoint
        let sensor: Sensor
        let radius: CGFloat          // screen points
        let footprint: MKMapRect     // approximate scan × track pixel footprint, in map units
    }

    /// Items sorted by x position, so a tile can find its points with a binary search.
    let items: [Item]
    /// The detections in the same order as `items`.
    let detections: [FireDetection]

    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    init(detections input: [FireDetection]) {
        let built: [(Item, FireDetection)] = input.map { d in
            let p = MKMapPoint(d.coordinate)
            let perMeter = MKMapPointsPerMeterAtLatitude(d.latitude)
            let fallback = d.sensor == .modis ? 1.0 : 0.375
            let w = (d.scan ?? fallback) * 1000 * perMeter
            let h = (d.track ?? fallback) * 1000 * perMeter
            let rect = MKMapRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            return (Item(point: p, sensor: d.sensor, radius: SensorPalette.radius(frp: d.frp), footprint: rect), d)
        }.sorted { $0.0.point.x < $1.0.point.x }
        items = built.map(\.0)
        detections = built.map(\.1)
        maxFootprint = items.reduce(0) { max($0, $1.footprint.width, $1.footprint.height) }
        super.init()
    }

    /// The largest footprint, used to pad tile edges so footprints that cross a tile boundary aren't cut off.
    let maxFootprint: Double

    /// Indices of the items whose x is in [minX, maxX], found with binary search.
    func indices(minX: Double, maxX: Double) -> Range<Int> {
        func lowerBound(_ x: Double) -> Int {
            var lo = 0, hi = items.count
            while lo < hi { let mid = (lo + hi) / 2; if items[mid].point.x < x { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        return lowerBound(minX)..<lowerBound(maxX.nextUp)
    }

    /// Every detection under a click, nearest first. The click hits a point if it lands on
    /// its marker or inside its pixel footprint. Overlapping detections are all returned.
    func hits(at p: MKMapPoint, zoomScale: Double) -> [FireDetection] {
        let slop = 4.0 / zoomScale
        let reach = max(14.0 / zoomScale, maxFootprint / 2) + slop
        var found: [(Double, Int)] = []
        for i in indices(minX: p.x - reach, maxX: p.x + reach) {
            let it = items[i]
            let dx = it.point.x - p.x, dy = it.point.y - p.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let onMarker = dist <= Double(it.radius) / zoomScale + slop
            if onMarker || it.footprint.contains(p) { found.append((dist, i)) }
        }
        return found.sorted { $0.0 < $1.0 }.map { detections[$0.1] }
    }
}

/// Draws a DetectionOverlay. MapKit calls `draw` for each visible tile, on background threads.
nonisolated final class DetectionRenderer: MKOverlayRenderer, @unchecked Sendable {
    private let detectionOverlay: DetectionOverlay

    init(detectionOverlay: DetectionOverlay) {
        self.detectionOverlay = detectionOverlay
        super.init(overlay: detectionOverlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let o = detectionOverlay
        guard !o.items.isEmpty else { return }

        let px = 1 / Double(zoomScale)                 // map units per screen point
        let pad = max(16 * px, o.maxFootprint)         // so markers on tile edges aren't cut off
        let area = mapRect.insetBy(dx: -pad, dy: -pad)
        let range = o.indices(minX: area.minX, maxX: area.maxX)
        guard !range.isEmpty else { return }

        // When zoomed in far enough that a 375 m pixel is at least 7 points wide,
        // also draw each detection's real pixel footprint (scan × track).
        let showFootprints = 0.375 * 1000 * MKMapPointsPerMeterAtLatitude(35) * Double(zoomScale) > 7

        context.setLineJoin(.round)

        // Passes: 0 = pixel footprints, 1 = soft glow (adds up where detections overlap),
        // 2 = MODIS markers, 3 = VIIRS markers. VIIRS goes last so its finer 375 m
        // detections are never hidden under the coarser MODIS ones.
        // Each marker is a colored shape with a dark outline and a small white-hot center,
        // so it stays visible on both bright desert and dark ocean imagery.
        for pass in 0..<4 {
            if pass == 0 && !showFootprints { continue }
            context.setBlendMode(pass == 1 ? .plusLighter : .normal)

            for i in range {
                let it = o.items[i]
                if pass == 2 && it.sensor != .modis { continue }
                if pass == 3 && it.sensor != .viirs { continue }
                guard area.contains(it.point) else { continue }
                let c = point(for: it.point)
                let r = CGFloat(Double(it.radius) * px)

                switch pass {
                case 0:
                    let rect = self.rect(for: it.footprint)
                    context.setFillColor(SensorPalette.cgColor(it.sensor, alpha: 0.10))
                    context.setStrokeColor(SensorPalette.cgColor(it.sensor, alpha: 0.75))
                    context.setLineWidth(CGFloat(1.0 * px))
                    context.addRect(rect)
                    context.drawPath(using: .fillStroke)
                case 1:
                    // Two stacked discs make a glow that is brighter toward the middle.
                    for (scale, alpha) in [(2.6, 0.07), (1.7, 0.12)] {
                        let g = r * scale
                        context.setFillColor(SensorPalette.cgColor(it.sensor, alpha: alpha))
                        context.fillEllipse(in: CGRect(x: c.x - g, y: c.y - g, width: g * 2, height: g * 2))
                    }
                default:
                    context.setFillColor(SensorPalette.cgColor(it.sensor, alpha: 0.95))
                    context.setStrokeColor(CGColor(gray: 0, alpha: 0.7))
                    context.setLineWidth(CGFloat(1.0 * px))
                    if it.sensor == .modis {
                        // MODIS = circle
                        context.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    } else {
                        // VIIRS = diamond. A different shape as well as a different color, so the sensors can be told apart even without color vision.
                        let d = r * 1.15
                        context.move(to: CGPoint(x: c.x, y: c.y - d))
                        context.addLine(to: CGPoint(x: c.x + d, y: c.y))
                        context.addLine(to: CGPoint(x: c.x, y: c.y + d))
                        context.addLine(to: CGPoint(x: c.x - d, y: c.y))
                        context.closePath()
                    }
                    context.drawPath(using: .fillStroke)
                    let core = r * 0.36
                    context.setFillColor(CGColor(gray: 1, alpha: 0.9))
                    context.fillEllipse(in: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2))
                }
            }
        }
    }
}
