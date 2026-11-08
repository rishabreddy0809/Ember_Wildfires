//  InspectorView.swift
//  The right-hand panel that shows every value of the selected detection.
//  If the click landed on overlapping detections, a pager lets you step through all of them.
//  They are listed one by one and never merged.

import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var store: FireStore

    var body: some View {
        Group {
            if let d = store.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.selectionStack.count > 1 { StackPager(store: store) }
                        Hero(d: d)
                        Measurements(d: d)
                        Details(d: d)
                        RawColumns(d: d)
                        Actions(d: d, store: store)
                    }
                    .padding(14)
                }
                .id(d.id)
                .transition(.opacity)
            } else {
                EmptyInspector()
            }
        }
        .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        .animation(.snappy(duration: 0.2), value: store.selected?.id)
    }
}

// MARK: - Empty state

private struct EmptyInspector: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(width: 84, height: 84)
                Image(systemName: "scope").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            }
            Text("No detection selected").font(.headline)
            Text("Click any point on the map to see all of its FIRMS data. When detections overlap, you can step through each one.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overlap pager

private struct StackPager: View {
    let store: FireStore
    var body: some View {
        HStack(spacing: 8) {
            Button { store.stepSelection(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: [])
            VStack(alignment: .leading, spacing: 4) {
                HUDLabel("\(store.selectionIndex + 1) of \(store.selectionStack.count) under cursor")
                HStack(spacing: 3) {
                    ForEach(Array(store.selectionStack.enumerated()), id: \.element.id) { i, d in
                        SensorGlyph(sensor: d.sensor, size: i == store.selectionIndex ? 9 : 6, glow: i == store.selectionIndex)
                            .frame(width: 10, height: 10)
                            .onTapGesture { store.selectionIndex = i }
                    }
                }
            }
            Spacer()
            Button { store.stepSelection(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: [])
        }
        .buttonStyle(.borderless)
        .padding(10)
        .background(Theme.panel, in: .rect(cornerRadius: 10))
        .help("Overlapping detections are kept separate. Use [ and ] to step through them.")
    }
}

// MARK: - Hero

private struct Hero: View {
    let d: FireDetection
    var body: some View {
        let c = Theme.color(d.sensor)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SensorGlyph(sensor: d.sensor, size: 14)
                Text(d.sensor.rawValue)
                    .font(.system(size: 13, weight: .black).width(.expanded)).tracking(2)
                    .foregroundStyle(c)
                Text(d.satelliteName)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(c.opacity(0.15), in: .capsule)
                Spacer()
                Label(d.dayNight.label, systemImage: d.dayNight == .night ? "moon.stars.fill" : "sun.max.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(d.dayNight == .night ? Color.indigo : Color.yellow)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(d.frp.map { String(format: $0 >= 100 ? "%.0f" : "%.2f", $0) } ?? "—")
                    .font(.hudNumber(40))
                    .foregroundStyle(LinearGradient(colors: [.white, c], startPoint: .top, endPoint: .bottom))
                Text("MW").font(.system(size: 13, weight: .bold).width(.expanded)).foregroundStyle(.secondary)
                Spacer()
            }
            HUDLabel("Fire radiative power")
            FRPMeter(frp: d.frp, color: c)

            if let t = d.acquiredAt {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(identifier: "UTC")!)) + " UTC")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("\(t.formatted(date: .omitted, time: .shortened)) local · \(t.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [c.opacity(0.22), c.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.opacity(0.35)))
    }
}

/// FRP on a log scale from 0.1 MW to 10,000 MW. FRP spans many orders of magnitude, so a linear bar would be unreadable.
private struct FRPMeter: View {
    let frp: Double?
    let color: Color
    var body: some View {
        let v = max(0.1, frp ?? 0.1)
        let f = min(1, max(0, (log10(v) + 1) / 5))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.6), color, .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * f))
                    .shadow(color: color, radius: 6)
            }
        }
        .frame(height: 6)
        .overlay(alignment: .bottom) {
            HStack {
                ForEach(["0.1", "1", "10", "100", "1k", "10k"], id: \.self) { t in
                    Text(t).frame(maxWidth: .infinity, alignment: t == "0.1" ? .leading : (t == "10k" ? .trailing : .center))
                }
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.tertiary)
            .offset(y: 13)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Measurements

private struct Measurements: View {
    let d: FireDetection
    var body: some View {
        HStack(spacing: 10) {
            BrightnessCard(label: d.brightnessColumnName, kelvin: d.brightness, hint: d.sensor == .modis ? "4 µm (ch 21/22)" : "3.7 µm (I-4)")
            BrightnessCard(label: d.brightness2ColumnName, kelvin: d.brightness2, hint: d.sensor == .modis ? "11 µm (ch 31)" : "11.5 µm (I-5)")
        }
        ConfidenceCard(confidence: d.confidence, sensor: d.sensor)
    }
}

private struct BrightnessCard: View {
    let label: String
    let kelvin: Double?
    let hint: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HUDLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(kelvin.map { String(format: "%.1f", $0) } ?? "—").font(.hudNumber(18))
                Text("K").font(.caption.bold()).foregroundStyle(.secondary)
            }
            // A thermometer bar from 250 K to 500 K
            let f = kelvin.map { min(1, max(0, ($0 - 250) / 250)) } ?? 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Theme.heat).frame(width: max(3, g.size.width * f))
                }
            }.frame(height: 3)
            Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: .rect(cornerRadius: 10))
    }
}

/// MODIS confidence is shown as a percent gauge, and VIIRS as three steps. Each matches how that sensor reports it.
private struct ConfidenceCard: View {
    let confidence: DetectionConfidence
    let sensor: Sensor
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HUDLabel("Confidence")
                Text(confidence.displayText).font(.hudNumber(18))
                Text(sensor == .modis ? "MODIS: 0–100 %" : "VIIRS: low · nominal · high")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            switch confidence {
            case .percent(let p):
                Gauge(value: Double(p), in: 0...100) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(Theme.color(sensor))
                    .scaleEffect(0.9)
            case .category(let c):
                HStack(spacing: 3) {
                    ForEach(VIIRSConfidence.allCases, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level.rank <= c.rank ? Theme.color(sensor) : Color.white.opacity(0.08))
                            .frame(width: 18, height: 6 + CGFloat(level.rank) * 6)
                    }
                }
                .frame(height: 20, alignment: .bottom)
            case .unknown:
                EmptyView()
            }
        }
        .padding(10)
        .background(Theme.panel, in: .rect(cornerRadius: 10))
    }
}

// MARK: - Details

private struct Details: View {
    let d: FireDetection
    var body: some View {
        Panel("Detection") {
            DataRow(label: "Latitude", value: String(format: "%.5f°", d.latitude))
            DataRow(label: "Longitude", value: String(format: "%.5f°", d.longitude))
            DataRow(label: "Pixel (scan × track)", value: footprint)
            DataRow(label: "acq_date / acq_time", value: "\(d.acqDate)  \(d.acqTime)")
            DataRow(label: "Satellite", value: "\(d.satellite) (\(d.satelliteName))")
            if let i = d.instrument { DataRow(label: "Instrument", value: i) }
            DataRow(label: "Version", value: d.version)
            DataRow(label: "Source", value: d.source)
            if let t = d.type { DataRow(label: "Type", value: "\(t) · \(typeName(t))") }
        }
    }

    private var footprint: String {
        guard let s = d.scan, let t = d.track else { return "—" }
        return String(format: "%.2f × %.2f km", s, t)
    }

    private func typeName(_ t: Int) -> String {
        switch t {
        case 0: "vegetation fire"
        case 1: "active volcano"
        case 2: "other static land"
        case 3: "offshore"
        default: "unknown"
        }
    }
}

/// Every column exactly as FIRMS wrote it.
private struct RawColumns: View {
    let d: FireDetection
    @State private var expanded = true
    var body: some View {
        Panel("All FIRMS columns · \(d.allColumns.count)") {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 0) {
                    ForEach(Array(d.allColumns.enumerated()), id: \.offset) { i, col in
                        HStack {
                            Text(col.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(col.value.isEmpty ? "∅" : col.value).textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(i.isMultiple(of: 2) ? Color.white.opacity(0.03) : .clear)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Raw values").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Actions: View {
    let d: FireDetection
    let store: FireStore
    var body: some View {
        HStack {
            Button("Center", systemImage: "location.viewfinder") { store.focus(on: d) }
            Button("Copy Coordinates", systemImage: "doc.on.doc") {
                copy(String(format: "%.5f, %.5f", d.latitude, d.longitude))
            }
            Button("Copy Row", systemImage: "tablecells") {
                copy(d.allColumns.map(\.name).joined(separator: ",") + "\n" + d.allColumns.map(\.value).joined(separator: ","))
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
