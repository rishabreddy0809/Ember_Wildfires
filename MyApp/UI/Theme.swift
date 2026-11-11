//  Theme.swift
//  Shared colors, fonts, and small reusable views, so every screen looks consistent.
//
//  The look is a dark "mission console":
//  • A near-black, slightly cool background, so the fire colors are the brightest thing on screen.
//  • Amber for MODIS and sky blue for VIIRS. Orange and blue are the color pair that stays
//    easiest to tell apart for people with color blindness. The two sensors also use
//    different shapes (circle vs diamond), so you never have to rely on color alone.
//  • Three kinds of type, each with one job: wide SF Pro Expanded for the brand and big
//    numbers, small uppercase labels for names, and SF Mono for anything that is data.
//  • Sections are separated by thin lines instead of boxes. Boxes are kept for things
//    you can click or that hold one self-contained reading.

import SwiftUI

enum Theme {
    // Brand
    static let ember = Color(red: 1.00, green: 0.42, blue: 0.17)
    static let emberHot = Color(red: 1.00, green: 0.72, blue: 0.30)

    // Sensors (must match SensorPalette in DetectionOverlay.swift)
    static let modis = Color(red: 1.00, green: 0.63, blue: 0.20)
    static let viirs = Color(red: 0.27, green: 0.76, blue: 1.00)

    // Status
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.34)
    static let ok = Color(red: 0.36, green: 0.86, blue: 0.56)

    // Surfaces
    static let background = Color(red: 0.024, green: 0.027, blue: 0.039)
    static let panel = Color.white.opacity(0.045)
    static let panelRaised = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.09)
    /// Darkens the floating glass panels so their text stays readable over bright map imagery.
    static let glassTint = Color(red: 0.03, green: 0.04, blue: 0.07).opacity(0.55)

    // Text
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)

    static func color(_ s: Sensor) -> Color { s == .modis ? modis : viirs }

    /// The yellow → orange → red "heat" gradient used for brand accents.
    static let heat = LinearGradient(colors: [Color(red: 1, green: 0.80, blue: 0.36), ember, Color(red: 0.90, green: 0.18, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Corner radius for cards and for floating glass panels.
    static let cardRadius: CGFloat = 10
    static let glassRadius: CGFloat = 16
}

extension Font {
    /// Small uppercase label.
    static let hudLabel = Font.system(size: 10, weight: .semibold)
    /// Big instrument-style number.
    static func hudNumber(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).width(.expanded).monospacedDigit() }
    /// Data values: coordinates, dates, counts, raw columns.
    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    /// Sensor names and other short wide titles.
    static func wide(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight).width(.expanded) }
    /// Small explanatory text under a control.
    static let footnoteSmall = Font.system(size: 10.5)
}

/// Small uppercase label, for example "DETECTIONS".
struct HUDLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.hudLabel)
            .tracking(0.9)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

/// A titled group of content with no box around it. Sections are divided by `SectionRule`.
struct SidebarSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HUDLabel(title)
                Spacer()
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The thin line between sections.
struct SectionRule: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// A rounded card with a thin border, used in the inspector.
struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { HUDLabel(title) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension View {
    /// The standard card background: a faint fill and a thin border.
    func card(radius: CGFloat = Theme.cardRadius, fill: Color = Theme.panel) -> some View {
        background(fill, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline))
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
                Rectangle().fill(c).rotationEffect(.degrees(45)).scaleEffect(0.76)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: glow ? c.opacity(0.85) : .clear, radius: size * 0.4)
        .accessibilityHidden(true)
    }
}

/// A thin horizontal meter. `fraction` is 0...1.
struct MeterBar<Fill: ShapeStyle>: View {
    let fraction: Double
    let fill: Fill
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(fill).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// A label/value row used in the inspector.
struct DataRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.mono)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The filled orange button used for the one main action on a screen.
struct EmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Theme.heat, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .shadow(color: Theme.ember.opacity(isEnabled ? 0.45 : 0), radius: 10, y: 3)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .saturation(isEnabled ? 1 : 0.25)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.rect(cornerRadius: 10))
    }
}

/// A quiet bordered button for secondary actions.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? Theme.panelRaised : Theme.panel, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect(cornerRadius: 8))
    }
}

extension Int {
    /// 12345 → "12,345"
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
