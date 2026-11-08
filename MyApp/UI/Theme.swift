//  Theme.swift
//  Shared colors, fonts, and small reusable views, so every screen looks consistent.
//
//  The look is a dark "operations center" theme:
//  • A near-black background with a warm tint, so the fire colors stand out.
//  • Amber for MODIS and cyan for VIIRS. Orange and blue are the color pair that stays
//    easiest to tell apart for people with color blindness. The two sensors also use
//    different shapes (circle vs diamond), so you don't have to rely on color at all.
//  • Labels use the wide SF Pro Expanded font, like aircraft instruments,
//    and numbers use fixed-width digits so they don't jump around when they change.

import SwiftUI

enum Theme {
    static let ember = Color(red: 1.00, green: 0.42, blue: 0.11)
    static let modis = Color(red: 1.00, green: 0.62, blue: 0.10)
    static let viirs = Color(red: 0.20, green: 0.90, blue: 1.00)
    static let danger = Color(red: 1.00, green: 0.30, blue: 0.30)
    static let panel = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.08)

    static func color(_ s: Sensor) -> Color { s == .modis ? modis : viirs }

    /// The amber → red → white "heat" gradient used for brand accents.
    static let heat = LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.35), ember, Color(red: 0.85, green: 0.12, blue: 0.20)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Font {
    /// Small, wide, uppercase label style.
    static let hudLabel = Font.system(size: 9.5, weight: .bold).width(.expanded)
    static func hudNumber(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.expanded).monospacedDigit() }
    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
}

/// Small uppercase section label, for example "DETECTIONS".
struct HUDLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.hudLabel)
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
}

/// A rounded panel with a thin border, used for each sidebar section.
struct Panel<Content: View>: View {
    var title: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    HUDLabel(title)
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

/// The marker shape for each sensor: a circle for MODIS and a diamond for VIIRS. It matches the map markers.
struct SensorGlyph: View {
    let sensor: Sensor
    var size: CGFloat = 12
    var glow = true

    var body: some View {
        let c = Theme.color(sensor)
        Group {
            if sensor == .modis {
                Circle().fill(c)
            } else {
                Rectangle().fill(c).rotationEffect(.degrees(45)).scaleEffect(0.78)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if sensor == .modis { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1) }
        }
        .shadow(color: glow ? c.opacity(0.9) : .clear, radius: size * 0.45)
    }
}

/// A label/value row used in the inspector.
struct DataRow: View {
    let label: String
    let value: String
    var mono = true
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .mono : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

extension Int {
    /// 12345 → "12,345"
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
