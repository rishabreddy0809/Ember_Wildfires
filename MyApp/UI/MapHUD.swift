//  MapHUD.swift
//  The glass panels that float over the map: legend, overpass timeline, loading pill, and banners.

import SwiftUI
import Charts
import CoreLocation

// MARK: - Legend

/// Top-right legend: what each marker shape means and how marker size relates to FRP.
/// Clicking a sensor row shows or hides it, the same as ⌘1 and ⌘2.
struct LegendHUD: View {
    let store: FireStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Sensor.allCases) { s in
                let isOn = store.visibleSensors.contains(s)
                Button { withAnimation(.snappy) { store.toggle(s) } } label: {
                    HStack(spacing: 8) {
                        SensorGlyph(sensor: s, size: 10, glow: isOn)
                        Text(s.rawValue).font(.wide(10.5)).tracking(1)
                        Text(s.nominalResolution).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Text(store.count(s).grouped)
                            .font(.mono(11, .semibold))
                            .contentTransition(.numericText())
                    }
                    .opacity(isOn ? 1 : 0.4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(isOn ? "Hide" : "Show") \(s.rawValue) (\(s == .modis ? "⌘1" : "⌘2"))")
                .accessibilityLabel("\(s.rawValue), \(store.count(s)) detections, \(isOn ? "shown" : "hidden")")
            }

            SectionRule()

            HStack(alignment: .center, spacing: 5) {
                ForEach([1.0, 10, 100, 1000], id: \.self) { frp in
                    let r = SensorPalette.radius(frp: frp)
                    Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                        .frame(width: r * 2, height: r * 2)
                }
                Spacer(minLength: 6)
                Text("1 → 1,000 MW").font(.mono(9.5)).foregroundStyle(Theme.textSecondary)
            }
            .frame(height: 24)
            .help("Marker size shows fire radiative power on a log scale")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Marker size shows fire radiative power, from 1 to 1,000 megawatts, on a log scale")
        }
        .padding(13)
        .frame(width: 222)
        .glassEffect(.regular.tint(Theme.glassTint), in: .rect(cornerRadius: Theme.glassRadius))
    }
}

// MARK: - Timeline dock

/// Bottom panel: detections per hour (UTC) with MODIS drawn upward and VIIRS drawn downward
/// from a shared baseline, so the two sensors can be compared overpass by overpass.
/// The header also shows the coordinate under the mouse pointer.
struct TimelineDock: View {
    let store: FireStore
    let cursor: CLLocationCoordinate2D?
    @State private var hovered: HourBin?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HUDLabel("Detections per hour · UTC")
                if let h = hovered {
                    HStack(spacing: 10) {
                        Text(Self.hourLabel(h.hour))
                        Text("MODIS \(h.modis)").foregroundStyle(Theme.modis)
                        Text("VIIRS \(h.viirs)").foregroundStyle(Theme.viirs)
                    }
                    .font(.mono(10.5, .semibold))
                    .fixedSize()
                    .transition(.opacity)
                } else {
                    HStack(spacing: 10) {
                        Label("MODIS", systemImage: "arrow.up").foregroundStyle(Theme.modis)
                        Label("VIIRS", systemImage: "arrow.down").foregroundStyle(Theme.viirs)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .labelStyle(.titleAndIcon)
                    .transition(.opacity)
                }
                Spacer(minLength: 12)
                CursorReadout(cursor: cursor)
                Text("\(store.displayedDetections.count.grouped) shown")
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .animation(.easeOut(duration: 0.12), value: hovered)

            TimelineChart(store: store, hovered: $hovered)
        }
        .padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: 860)
        .glassEffect(.regular.tint(Theme.glassTint), in: .rect(cornerRadius: Theme.glassRadius))
    }

    /// "Nov 7 · 15:00" (the hour that starts then), always in UTC and on a 24-hour clock.
    private static func hourLabel(_ hour: Date) -> String {
        let h = FireQuery.utc.component(.hour, from: hour)
        let day = hour.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
        return String(format: "%@ · %02d:00", day, h)
    }
}

/// How many detections each sensor made in one UTC hour.
struct HourBin: Identifiable, Equatable {
    let hour: Date
    var modis = 0
    var viirs = 0
    var id: Date { hour }
}

private struct CursorReadout: View {
    let cursor: CLLocationCoordinate2D?

    var body: some View {
        Label {
            Text(cursor.map { "\(lat($0.latitude))  \(lon($0.longitude))" } ?? "—")
                .frame(minWidth: 158, alignment: .leading)
        } icon: {
            Image(systemName: "scope")
        }
        .font(.mono(10.5))
        .foregroundStyle(cursor == nil ? Theme.textTertiary : .primary)
        .accessibilityLabel("Pointer position")
    }

    private func lat(_ v: Double) -> String { String(format: "%07.4f°%@", abs(v), v >= 0 ? "N" : "S") }
    private func lon(_ v: Double) -> String { String(format: "%08.4f°%@", abs(v), v >= 0 ? "E" : "W") }
}

/// The mirrored bar chart. It is its own view so that moving the mouse over the map
/// (which updates the cursor readout) doesn't redo the counting.
private struct TimelineChart: View {
    let store: FireStore
    @Binding var hovered: HourBin?
    @State private var bins: [HourBin] = []
    @State private var selection: Date?

    private struct DataKey: Equatable {
        let version: Int
        let sensors: Set<Sensor>
    }

    var body: some View {
        Group {
            if bins.isEmpty {
                Text(store.detections.isEmpty ? "No detections loaded yet" : "No detections to plot. Both sensors are hidden.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
        .frame(height: 92)
        .onChange(of: DataKey(version: store.dataVersion, sensors: store.visibleSensors), initial: true) {
            bins = Self.makeBins(store.displayedDetections)
        }
        .onChange(of: selection) {
            guard let selection else { hovered = nil; return }
            let hour = FireQuery.utc.dateInterval(of: .hour, for: selection)?.start ?? selection
            hovered = bins.first { $0.hour == hour } ?? HourBin(hour: hour)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(bins) { b in
                if b.modis > 0 {
                    BarMark(x: .value("Hour", b.hour, unit: .hour), y: .value("MODIS", b.modis), width: .ratio(0.82))
                        .foregroundStyle(Theme.modis)
                        .opacity(dim(b))
                }
                if b.viirs > 0 {
                    BarMark(x: .value("Hour", b.hour, unit: .hour), y: .value("VIIRS", -b.viirs), width: .ratio(0.82))
                        .foregroundStyle(Theme.viirs)
                        .opacity(dim(b))
                }
            }
            RuleMark(y: .value("Baseline", 0))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.white.opacity(0.35))
            if let h = hovered {
                RuleMark(x: .value("Hour", h.hour.addingTimeInterval(1800)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $selection)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: tickHours, calendar: FireQuery.utc)) { value in
                let date = value.as(Date.self)
                let isMidnight = date.map { FireQuery.utc.component(.hour, from: $0) == 0 } ?? false
                AxisGridLine().foregroundStyle(isMidnight ? Color.white.opacity(0.22) : Theme.hairline)
                AxisValueLabel(centered: false) {
                    // Midnight ticks show the date. The others show the UTC hour.
                    if let date {
                        Text(isMidnight ? date.formatted(Self.dayFormat)
                                        : String(format: "%02d:00", FireQuery.utc.component(.hour, from: date)))
                            .font(.mono(9, isMidnight ? .bold : .medium))
                            .foregroundStyle(isMidnight ? Color.white.opacity(0.9) : Theme.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    // VIIRS counts are plotted below zero, so show the size without the minus sign.
                    if let v = value.as(Int.self) { Text("\(abs(v))") }
                }
                .font(.mono(9))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityLabel("Detections per hour, MODIS above the line and VIIRS below")
    }

    private static let utcZone = TimeZone(identifier: "UTC")!
    private static let dayFormat = Date.FormatStyle(timeZone: utcZone).month(.abbreviated).day()

    /// Hours between axis labels: every 3 hours for a day or two, wider for longer ranges.
    private var tickHours: Int {
        let hours = domain.upperBound.timeIntervalSince(domain.lowerBound) / 3600
        return [3, 6, 12, 24].first { hours / Double($0) <= 16 } ?? 24
    }

    private func dim(_ b: HourBin) -> Double {
        guard let h = hovered else { return 1 }
        return h.hour == b.hour ? 1 : 0.45
    }

    /// The whole queried date range, so quiet hours between overpasses are visible too.
    private var domain: ClosedRange<Date> {
        let first = bins.first?.hour ?? .now
        let last = (bins.last?.hour ?? .now).addingTimeInterval(3600)
        guard let q = store.loadedQuery else { return first...last }
        let end = FireQuery.utc.date(byAdding: .day, value: 1, to: q.endDate) ?? q.endDate
        return min(q.startDate, first)...max(end, last)
    }

    private static func makeBins(_ detections: [FireDetection]) -> [HourBin] {
        var byHour: [Date: HourBin] = [:]
        for d in detections {
            guard let t = d.acquiredAt else { continue }
            let hour = FireQuery.utc.dateInterval(of: .hour, for: t)?.start ?? t
            var bin = byHour[hour] ?? HourBin(hour: hour)
            if d.sensor == .modis { bin.modis += 1 } else { bin.viirs += 1 }
            byHour[hour] = bin
        }
        return byHour.values.sorted { $0.hour < $1.hour }
    }
}

// MARK: - Status pills and banners

/// Top-center pill shown while downloading.
struct LoadingPill: View {
    let status: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(status).font(.system(size: 12, weight: .semibold))
            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .keyboardShortcut(".", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular.tint(Theme.viirs.opacity(0.15)), in: .capsule)
    }
}

/// Top-center pill shown when the map holds an earlier download instead of fresh data.
struct CachedPill: View {
    let updated: Date

    var body: some View {
        Label("Offline copy · downloaded \(updated.formatted(.relative(presentation: .named)))",
              systemImage: "externaldrive.fill.badge.timemachine")
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .glassEffect(.regular.tint(Theme.modis.opacity(0.15)), in: .capsule)
    }
}

/// Banner for errors and empty results, shown above the timeline.
struct BannerView: View {
    let symbol: String
    let title: String
    let message: String?
    let tint: Color
    var primary: (label: String, action: () -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .bold))
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let primary {
                Button(primary.label, action: primary.action).buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
            }
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(13)
        .frame(maxWidth: 560)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: Theme.glassRadius))
    }
}
