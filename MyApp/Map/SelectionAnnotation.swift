//  SelectionAnnotation.swift
//  The animated "target lock" ring drawn on the selected detection.

import MapKit
import AppKit
import QuartzCore

/// A map annotation placed on the selected detection.
final class SelectionAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let detectionID: UUID
    let sensor: Sensor

    init(detection: FireDetection) {
        coordinate = detection.coordinate
        detectionID = detection.id
        sensor = detection.sensor
    }
}

/// Two rings: one pulses outward and one stays fixed, with crosshair ticks, colored by sensor.
final class SelectionRingView: MKAnnotationView {
    static let reuseID = "SelectionRing"
    private let pulse = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let ticks = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        wantsLayer = true
        canShowCallout = false
        let center = CGRect(x: 16, y: 16, width: 32, height: 32)
        for l in [pulse, ring, ticks] {
            l.frame = bounds
            l.fillColor = nil
            layer?.addSublayer(l)
        }
        pulse.path = CGPath(ellipseIn: center, transform: nil)
        pulse.lineWidth = 2
        ring.path = CGPath(ellipseIn: center.insetBy(dx: 4, dy: 4), transform: nil)
        ring.lineWidth = 2
        let t = CGMutablePath()
        for (a, b) in [((32.0, 6.0), (32.0, 14.0)), ((32.0, 50.0), (32.0, 58.0)), ((6.0, 32.0), (14.0, 32.0)), ((50.0, 32.0), (58.0, 32.0))] {
            t.move(to: CGPoint(x: a.0, y: a.1)); t.addLine(to: CGPoint(x: b.0, y: b.1))
        }
        ticks.path = t
        ticks.lineWidth = 2
        ticks.lineCap = .round
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(sensor: Sensor) {
        let color = SensorPalette.cgColor(sensor)
        pulse.strokeColor = color
        ring.strokeColor = CGColor(gray: 1, alpha: 0.95)
        ticks.strokeColor = color

        pulse.removeAllAnimations()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // Scale from the center of the layer
        pulse.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pulse.position = CGPoint(x: bounds.midX, y: bounds.midY)
        pulse.add(group, forKey: "pulse")
    }
}
