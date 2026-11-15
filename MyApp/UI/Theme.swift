//  Theme.swift
//  Shared colors and fonts, so every screen looks consistent.
//
//  The look is warm paper cards over a dark sky:
//  • Cream cards with soft corners hold everything you read. The globe and the map sit
//    behind them, and charts sit in navy insets, like windows onto the night side.
//  • A tall display serif (Instrument Serif) for names and big numbers, the system sans
//    for everything else, and SF Mono only for raw data values.
//  • One dark teal for actions. Amber for MODIS and sky blue for VIIRS: orange and blue
//    stay easy to tell apart with color blindness, and the two sensors also use different
//    shapes (circle and diamond), so you never have to rely on color alone.

import SwiftUI
import CoreText

enum Theme {
    // Paper
    static let cream0 = Color(red: 0.996, green: 0.973, blue: 0.937)
    static let cream1 = Color(red: 0.984, green: 0.933, blue: 0.882)
    static let chip = Color(red: 0.953, green: 0.922, blue: 0.875)
    static let line = Color(red: 0.906, green: 0.867, blue: 0.808)

    // Ink
    static let ink = Color(red: 0.078, green: 0.188, blue: 0.180)
    static let ink2 = Color(red: 0.357, green: 0.392, blue: 0.384)
    static let ink3 = Color(red: 0.549, green: 0.573, blue: 0.561)

    // Actions
    static let teal = Color(red: 0.118, green: 0.431, blue: 0.412)
    static let tealDark = Color(red: 0.082, green: 0.247, blue: 0.235)
    static let mint = Color(red: 0.863, green: 0.937, blue: 0.914)

    // Status
    static let good = Color(red: 0.247, green: 0.647, blue: 0.431)
    static let fair = Color(red: 0.945, green: 0.776, blue: 0.267)
    static let poor = Color(red: 0.890, green: 0.373, blue: 0.298)
    static let danger = poor
    static let ok = good

    // Dark surfaces: chart insets and the window backdrop
    static let navy = Color(red: 0.067, green: 0.106, blue: 0.220)
    static let sky0 = Color(red: 0.141, green: 0.102, blue: 0.227)
    static let sky1 = Color(red: 0.051, green: 0.043, blue: 0.094)
    static let onDark = Color(red: 0.992, green: 0.965, blue: 0.925)

    // Brand and sensors (the sensor colors must match SensorPalette in DetectionOverlay.swift)
    static let ember = Color(red: 0.933, green: 0.404, blue: 0.161)
    static let modis = Color(red: 1.00, green: 0.63, blue: 0.20)
    static let viirs = Color(red: 0.27, green: 0.76, blue: 1.00)

    static func color(_ s: Sensor) -> Color { s == .modis ? modis : viirs }

    /// Makes the bundled serif available to SwiftUI. Called once at launch.
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// Tall display serif for names and big numbers.
    static func serif(_ size: CGFloat) -> Font {
        NSFont(name: "InstrumentSerif-Regular", size: size) != nil
            ? .custom("InstrumentSerif-Regular", fixedSize: size)
            : .system(size: size, weight: .regular, design: .serif)
    }
    static func body(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Data values exactly as FIRMS wrote them: coordinates, dates, raw columns.
    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension Activity {
    var color: Color {
        switch self {
        case .intense: Theme.poor
        case .active: Theme.fair
        case .quiet: Theme.good
        }
    }
    var symbol: String {
        switch self {
        case .intense: "flame.fill"
        case .active: "exclamationmark"
        case .quiet: "checkmark"
        }
    }
    /// Used in a sentence: "An intense region".
    var phrase: String {
        switch self {
        case .intense: "Burning hard"
        case .active: "Active"
        case .quiet: "Quiet"
        }
    }
}

extension Int {
    /// 12345 → "12,345"
    var grouped: String { formatted(.number.grouping(.automatic)) }
}

nonisolated func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

/// "812 MW", "7.2 MW", or "—".
func megawatts(_ v: Double?) -> String {
    guard let v else { return "—" }
    return String(format: v >= 100 ? "%.0f MW" : "%.1f MW", v)
}

/// A whole-number percentage of `n` out of `total`, or "—" when there is nothing to divide by.
func share(_ n: Int, of total: Int) -> String {
    total == 0 ? "—" : "\(Int((Double(n) / Double(total) * 100).rounded()))%"
}

/// "4.51° N, 20.12° E"
func coordinateText(_ latitude: Double, _ longitude: Double, digits: Int = 2) -> String {
    String(format: "%.\(digits)f° %@, %.\(digits)f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
}

/// "Nov 14 – 15 UTC" for the days a query covers.
func dateRangeText(_ q: FireQuery) -> String {
    let style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day()
    let start = q.startDate.formatted(style)
    guard q.dayCount > 1 else { return start + " UTC" }
    let sameMonth = FireQuery.utc.component(.month, from: q.startDate) == FireQuery.utc.component(.month, from: q.endDate)
    let end = sameMonth ? "\(FireQuery.utc.component(.day, from: q.endDate))" : q.endDate.formatted(style)
    return "\(start) – \(end) UTC"
}
