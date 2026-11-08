//  SidebarView.swift
//  The left column. From top to bottom: brand header, per-sensor counts with on/off
//  toggles, an overpass timeline, quick stats, the area and date controls, the data
//  pipeline, and a status footer.

import SwiftUI
import Charts

struct SidebarView: View {
    @Bindable var store: FireStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BrandHeader()
                SensorTiles(store: store)
                ActivityPanel(detections: store.detections, visible: store.visibleSensors)
                StatsPanel(detections: store.displayedDetections)
                QueryPanel(store: store)
                PipelinePanel(store: store)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(store: store) }
        .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
    }
}

// MARK: - Brand

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Theme.heat)
                Image(systemName: "flame.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .frame(width: 34, height: 34)
            .shadow(color: Theme.ember.opacity(0.55), radius: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text("EMBER")
                    .font(.system(size: 17, weight: .black).width(.expanded))
                    .tracking(3)
                Text("Active Fire Detection · NASA FIRMS")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Sensor tiles

private struct SensorTiles: View {
    let store: FireStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Sensor.allCases) { s in
                    SensorTile(sensor: s,
                               count: store.count(s),
                               subtitle: subtitle(for: s),
                               isOn: store.visibleSensors.contains(s),
                               shortcut: s == .modis ? "⌘1" : "⌘2") {
                        withAnimation(.snappy) { store.toggle(s) }
                    }
                }
            }
            TotalBar(modis: store.count(.modis), viirs: store.count(.viirs))
        }
    }

    private func subtitle(for s: Sensor) -> String {
        let q = store.loadedQuery ?? store.query
        return s == .modis ? "Terra + Aqua · 1 km" : "\(q.viirsSatellite.label) · 375 m"
    }
}

private struct SensorTile: View {
    let sensor: Sensor
    let count: Int
    let subtitle: String
    let isOn: Bool
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let c = Theme.color(sensor)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SensorGlyph(sensor: sensor, size: 10, glow: isOn)
                    Text(sensor.rawValue)
                        .font(.system(size: 11, weight: .heavy).width(.expanded))
                        .tracking(1.2)
                    Spacer()
                    Image(systemName: isOn ? "eye.fill" : "eye.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOn ? c : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(count.grouped)
                    .font(.hudNumber(26))
                    .foregroundStyle(isOn ? c : .secondary)
                    .contentTransition(.numericText(value: Double(count)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack {
                    Text(subtitle)
                    Spacer()
                    Text(shortcut).foregroundStyle(.tertiary)
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [c.opacity(isOn ? 0.20 : 0.04), c.opacity(isOn ? 0.04 : 0.0)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(c.opacity(isOn ? (hovering ? 0.8 : 0.45) : 0.12), lineWidth: 1)
            }
            .shadow(color: c.opacity(isOn ? 0.22 : 0), radius: 12)
            .opacity(isOn ? 1 : 0.55)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(isOn ? "Hide" : "Show") \(sensor.rawValue) detections (\(shortcut))")
        .accessibilityLabel("\(sensor.rawValue), \(count) detections, \(isOn ? "shown" : "hidden")")
    }
}

/// A thin bar showing the MODIS / VIIRS split, plus the total.
private struct TotalBar: View {
    let modis: Int
    let viirs: Int

    var body: some View {
        let total = modis + viirs
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HUDLabel("Total detections")
                Spacer()
                Text(total.grouped)
                    .font(.system(size: 13, weight: .bold).width(.expanded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(total)))
            }
            GeometryReader { g in
                let f = total == 0 ? 0.5 : CGFloat(modis) / CGFloat(total)
                HStack(spacing: 2) {
                    Capsule().fill(Theme.modis.gradient).frame(width: max(2, (g.size.width - 2) * f))
                    Capsule().fill(Theme.viirs.gradient)
                }
                .opacity(total == 0 ? 0.25 : 1)
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Activity timeline

/// Detections per hour (UTC), stacked by sensor. The spikes line up with satellite overpasses.
private struct ActivityPanel: View {
    let detections: [FireDetection]
    let visible: Set<Sensor>

    private struct Bin: Identifiable {
        let hour: Date
        let sensor: Sensor
        let count: Int
        var id: String { "\(hour.timeIntervalSince1970)-\(sensor.rawValue)" }
    }

    private var bins: [Bin] {
        var counts: [Date: [Sensor: Int]] = [:]
        for d in detections where visible.contains(d.sensor) {
            guard let t = d.acquiredAt else { continue }
            let hour = FireQuery.utc.dateInterval(of: .hour, for: t)?.start ?? t
            counts[hour, default: [:]][d.sensor, default: 0] += 1
        }
        return counts.flatMap { hour, m in m.map { Bin(hour: hour, sensor: $0.key, count: $0.value) } }
            .sorted { $0.hour < $1.hour }
    }

    var body: some View {
        Panel("Overpass timeline · UTC") {
            let data = bins
            if data.isEmpty {
                Text("No detections to plot")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart(data) { b in
                    BarMark(x: .value("Hour", b.hour, unit: .hour),
                            y: .value("Detections", b.count))
                        .foregroundStyle(by: .value("Sensor", b.sensor.rawValue))
                        .cornerRadius(1.5)
                }
                .chartForegroundStyleScale(["MODIS": Theme.modis, "VIIRS": Theme.viirs])
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour(), centered: false)
                            .font(.system(size: 8.5))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel().font(.system(size: 8.5))
                    }
                }
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .frame(height: 100)
            }
        }
    }
}

// MARK: - Stats

private struct StatsPanel: View {
    let detections: [FireDetection]

    var body: some View {
        let frps = detections.compactMap(\.frp).sorted()
        let day = detections.filter { $0.dayNight == .day }.count
        let night = detections.filter { $0.dayNight == .night }.count
        let highConf = detections.filter {
            switch $0.confidence {
            case .percent(let p): p >= 80
            case .category(let c): c == .high
            case .unknown: false
            }
        }.count

        Panel("Snapshot") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Stat(label: "Peak FRP", value: frps.last.map { String(format: "%.0f", $0) } ?? "—", unit: "MW", tint: Theme.ember)
                    Stat(label: "Median FRP", value: frps.isEmpty ? "—" : String(format: "%.1f", frps[frps.count / 2]), unit: "MW")
                }
                GridRow {
                    Stat(label: "Day / Night", value: "\(day.grouped) / \(night.grouped)", unit: nil)
                    Stat(label: "High conf.", value: highConf.grouped, unit: nil)
                }
            }
            Text("High conf. = MODIS ≥ 80% or VIIRS “high”. Display only, nothing is filtered.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private struct Stat: View {
        let label: String
        let value: String
        let unit: String?
        var tint: Color = .primary
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HUDLabel(label)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.hudNumber(15)).foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let unit { Text(unit).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Query controls

private struct QueryPanel: View {
    @Bindable var store: FireStore

    var body: some View {
        Panel("Area & time", accessory: store.queryIsDirty ? AnyView(DirtyBadge()) : nil) {
            // Area preset menu
            Menu {
                ForEach(AreaPreset.all) { p in
                    Button(p.name) { store.selectPreset(p) }
                }
                if let _ = store.visibleMapBounds {
                    Divider()
                    Button("Use Visible Map Area") { store.useVisibleMapArea() }
                }
            } label: {
                Label(store.query.areaName, systemImage: "scope")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)

            BoundsEditor(bounds: $store.query.bounds, onEdit: { store.query.areaName = "Custom area" })

            HStack(spacing: 6) {
                Button("Use Visible Map", systemImage: "viewfinder") { store.useVisibleMapArea() }
                    .disabled(store.visibleMapBounds == nil)
                Button("Zoom to Area", systemImage: "arrow.down.right.and.arrow.up.left") { store.zoomToArea() }
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)

            if let err = store.query.bounds.validationError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }

            Divider().overlay(Theme.hairline)

            // Dates (FIRMS works in UTC days, so the picker shows UTC)
            LabeledContent("Start (UTC)") {
                DatePicker("", selection: $store.query.startDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            }
            LabeledContent("Days") {
                Stepper(value: $store.query.dayCount, in: 1...FireQuery.maxDayCount) {
                    Text("\(store.query.dayCount)").font(.mono)
                }
            }
            let chunks = store.query.dayChunks.count
            Text("\(FireQuery.firmsDateString(store.query.startDate)) → \(FireQuery.firmsDateString(store.query.endDate)) · \(chunks * 2) request\(chunks * 2 == 1 ? "" : "s") (FIRMS max 5 days each)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            Divider().overlay(Theme.hairline)

            Picker("Product", selection: $store.query.product) {
                Text("NRT").tag(FIRMSProduct.nearRealTime)
                Text("Archive").tag(FIRMSProduct.standard)
            }
            .pickerStyle(.segmented)
            .help("Near Real-Time arrives within about 3 hours. Standard (archive) is reprocessed, science-quality data and lags by a few months.")

            Picker("VIIRS satellite", selection: $store.query.viirsSatellite) {
                ForEach(VIIRSSatellite.allCases) { Text($0.label).tag($0) }
            }

            if store.query.viirsSatellite == .suomiNPP {
                Label("Suomi NPP stopped delivering new fire data on Nov 2, 2026. Use earlier dates, or choose NOAA-20/21 for recent fires.",
                      systemImage: "info.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.modis)
            }

            Text("\(store.query.modisSource) + \(store.query.viirsSource)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            Button {
                store.refresh()
            } label: {
                Label(store.isLoading ? "Fetching…" : "Fetch Detections", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ember)
            .controlSize(.large)
            .disabled(store.isLoading || store.query.bounds.validationError != nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private struct DirtyBadge: View {
        var body: some View {
            Text("UNSAVED").font(.hudLabel).tracking(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.ember.opacity(0.2), in: .capsule)
                .foregroundStyle(Theme.ember)
        }
    }
}

/// Four number fields for west/south/east/north.
private struct BoundsEditor: View {
    @Binding var bounds: GeoBounds
    var onEdit: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                field("N", \.north)
                    .gridCellColumns(2)
            }
            GridRow {
                field("W", \.west)
                field("E", \.east)
            }
            GridRow {
                field("S", \.south)
                    .gridCellColumns(2)
            }
        }
    }

    private func field(_ label: String, _ kp: WritableKeyPath<GeoBounds, Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.hudLabel).foregroundStyle(.secondary).frame(width: 12)
            TextField(label, value: Binding(get: { bounds[keyPath: kp] },
                                            set: { bounds[keyPath: kp] = $0; onEdit() }),
                      format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .font(.mono)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: 150)
    }
}

// MARK: - Pipeline

/// Shows the data flow and where a future processing step will go.
private struct PipelinePanel: View {
    let store: FireStore

    var body: some View {
        Panel("Data pipeline") {
            HStack(spacing: 4) {
                chip("Download", "arrow.down.circle")
                arrow
                chip("Parse", "tablecells")
                arrow
                ForEach(store.pipeline.steps, id: \.name) { step in
                    chip(step.name, "line.3.horizontal.decrease.circle", highlight: true)
                    arrow
                }
                chip("Map", "map")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text("Every detection is shown exactly as FIRMS reported it. Add processing steps in DetectionProcessor.swift.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            if store.skippedRows > 0 {
                Label("\(store.skippedRows) rows skipped (invalid coordinates)", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(Theme.modis)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
    }

    private func chip(_ text: String, _ symbol: String, highlight: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleOnly)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(highlight ? Theme.ember.opacity(0.16) : Color.white.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(highlight ? Theme.ember.opacity(0.5) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(highlight ? Theme.ember : .secondary)
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    let store: FireStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor, radius: 4)
                .phaseAnimator([1.0, 0.35]) { v, p in v.opacity(store.isLoading ? p : 1) } animation: { _ in .easeInOut(duration: 0.6) }

            VStack(alignment: .leading, spacing: 1) {
                if store.isLoading {
                    Text(store.loadingStatus.isEmpty ? "Working…" : store.loadingStatus)
                } else if let updated = store.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(updated, format: .relative(presentation: .named))")
                    }
                } else {
                    Text("No data yet")
                }
                if let updated = store.lastUpdated, !store.isLoading {
                    Text(updated.formatted(date: .abbreviated, time: .shortened) + (store.isShowingCachedData ? " · cached" : " · live"))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusColor: Color {
        if store.isLoading { return Theme.viirs }
        if store.error != nil { return Theme.danger }
        if store.isShowingCachedData { return Theme.modis }
        return store.lastUpdated == nil ? .gray : .green
    }
}
