//  Components.swift
//  The small reusable views every screen is built from: cards, pill tabs, buttons,
//  badges, big serif figures and the navy chart inset.

import SwiftUI

/// Cream paper card with soft corners.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = 24
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .foregroundStyle(Theme.ink)
            .background(LinearGradient(colors: [Theme.cream0, Theme.cream1], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

struct Divide: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// Round status mark with a symbol inside: a tick, a bang or a flame.
struct StatusIcon: View {
    let color: Color
    let symbol: String
    var size: CGFloat = 18
    var body: some View {
        Circle().fill(color)
            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.75), lineWidth: 1))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(Theme.ink.opacity(0.85)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Filled capsule badge, for example "🔥 Intense".
struct StatusBadge: View {
    let text: String
    let color: Color
    let symbol: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.white)
                .overlay(Image(systemName: symbol).font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink))
                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1))
                .frame(width: 18, height: 18)
            Text(text).font(.body(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        .padding(.leading, 9).padding(.trailing, 14).frame(height: 34)
        .background(color, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

/// Rounded tab. Dark teal when selected, paper chip otherwise.
struct PillTab<Leading: View>: View {
    let title: String
    let selected: Bool
    var onDark = false
    var compact = false
    @ViewBuilder var leading: Leading
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                leading
                Text(title).font(.body(compact ? 12.5 : 13.5, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 30 : 36)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous).strokeBorder(border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var fg: Color {
        if onDark { return selected ? Theme.ink : Theme.onDark.opacity(hover ? 1 : 0.8) }
        return selected ? .white : Theme.ink
    }
    private var bg: Color {
        if onDark { return selected ? Theme.cream0 : Color.white.opacity(hover ? 0.14 : 0.08) }
        return selected ? Theme.tealDark : (hover ? Theme.line : Theme.chip)
    }
    private var border: Color {
        if onDark { return selected ? .clear : Color.white.opacity(0.12) }
        return selected ? .clear : Theme.line
    }
}

extension PillTab where Leading == EmptyView {
    init(_ title: String, selected: Bool, onDark: Bool = false, compact: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, onDark: onDark, compact: compact, leading: { EmptyView() }, action: action)
    }
}

/// Teal capsule for the main action; mint capsule for the secondary one.
struct ActionButton: View {
    let title: String
    var primary = true
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.body(14, .semibold))
                .foregroundStyle(primary ? .white : Theme.tealDark)
                .padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 40)
                .background {
                    if primary {
                        Capsule().fill(LinearGradient(colors: [Theme.teal.opacity(hover ? 0.92 : 1), Theme.tealDark], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.tealDark.opacity(0.35), radius: 6, y: 4)
                    } else {
                        Capsule().fill(hover ? Theme.mint.opacity(0.75) : Theme.mint)
                            .overlay(Capsule().strokeBorder(Theme.teal.opacity(0.18), lineWidth: 1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.body(13, .medium)).foregroundStyle(Theme.teal).underline()
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Label, big serif figure, one-line explanation.
struct BigStat: View {
    let label: String
    let value: String
    let caption: String
    var size: CGFloat = 44
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.body(13, .semibold))
            Text(value).font(.serif(size)).monospacedDigit().contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(caption).font(.body(12)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Bar: View {
    let value: Double
    var tint: Color = Theme.teal
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(tint).frame(width: max(height, g.size.width * clamp01(value)))
            }
        }
        .frame(height: height)
    }
}

/// Navy panel for charts, like a window onto the night side.
struct DarkInset<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Theme.navy, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).overlay(Circle().strokeBorder(Theme.ink.opacity(0.6), lineWidth: 1)).frame(width: 11, height: 11)
            Text(text).font(.body(12.5)).lineLimit(1)
        }
    }
}

/// Round icon button used on the dark window strip.
struct RoundIcon: View {
    let symbol: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.ink : Theme.onDark)
                .frame(width: 30, height: 30)
                .background(active ? Theme.cream0 : Color.white.opacity(hover ? 0.16 : 0.08), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(active ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
    }
}

/// The marker shape for each sensor: a circle for MODIS and a diamond for VIIRS. It matches the globe and the map.
struct SensorGlyph: View {
    let sensor: Sensor
    var size: CGFloat = 11
    var body: some View {
        Group {
            if sensor == .modis {
                Circle().fill(Theme.modis).overlay(Circle().strokeBorder(Theme.ink.opacity(0.6), lineWidth: 1))
            } else {
                Rectangle().fill(Theme.viirs).overlay(Rectangle().strokeBorder(Theme.ink.opacity(0.6), lineWidth: 1))
                    .rotationEffect(.degrees(45)).scaleEffect(0.78)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A slider drawn to match the cards: a teal track and a white thumb.
struct PaperSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.05
    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width - 20)
            let t = clamp01((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 6)
                Capsule().fill(Theme.teal).frame(width: 10 + w * t, height: 6)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Theme.teal, lineWidth: 2))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: 20, height: 20)
                    .offset(x: w * t)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let nt = clamp01((v.location.x - 10) / w)
                let raw = range.lowerBound + nt * (range.upperBound - range.lowerBound)
                value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
            })
        }
        .frame(height: 20)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink3)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.ink3))
                .textFieldStyle(.plain).font(.body(13)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 11).frame(height: 32)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Highlights a row while the pointer is over it.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverRow(configuration: configuration) }
    struct HoverRow: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover || configuration.isPressed ? Theme.chip : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}

/// A label on the left and a value on the right, with a rule underneath.
struct FactRow: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.body(13)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 12)
                Text(value).font(mono ? .mono(12) : .body(13, .semibold))
                    .multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .padding(.vertical, 8)
            Divide()
        }
    }
}

/// The small message cards for errors and empty results.
struct NoticeCard: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String?
    var action: (label: String, run: () -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        Card(padding: 14, radius: 20) {
            HStack(alignment: .top, spacing: 12) {
                StatusIcon(color: color, symbol: symbol, size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body(14, .semibold))
                    if let message {
                        Text(message).font(.body(12.5)).foregroundStyle(Theme.ink2).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if let action { LinkButton(title: action.label, action: action.run) }
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink2)
                            .frame(width: 22, height: 22).background(Theme.chip, in: Circle())
                    }
                    .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
                }
            }
        }
        .frame(maxWidth: 560)
    }
}

/// Logo: a flame.
struct FlameMark: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.80, blue: 0.36), Theme.ember], startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
    }
}
