//  MapTab.swift
//  The Map view: the flat, zoomable map for close-up work, with each detection's real
//  pixel footprint when you zoom in far enough. Cards float over it: the base map
//  choice (top left), the legend (top right), and the hour-by-hour timeline (bottom).

import SwiftUI
import Charts
import CoreLocation

struct MapTab: View {
    @Bindable var store: FireStore
    @State private var cursor: CLLocationCoordinate2D?

    var body: some View {
        ZStack {
            DetectionMapView(store: store) { cursor = $0 }
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    HStack(spacing: 6) {
                        ForEach(MapStyleChoice.allCases) { s in
                            PillTab(s.rawValue, selected: store.mapStyle == s, onDark: true, compact: true) { store.mapStyle = s }
                        }
                    }
                    .padding(6)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    Spacer()
                    LegendCard(store: store)
                }
                Spacer()
                StatusNotices(store: store)
                // Leave room on the right for the map's zoom buttons.
                TimelineCard(store: store, cursor: cursor).padding(.trailing, 48)
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Legend

/// What each marker shape means and how marker size relates to fire radiative power.
/// Clicking a sensor row shows or hides it, the same as ⌘1 and ⌘2.
struct LegendCard: View {
    let store: FireStore

    var body: some View {
        Card(padding: 13, radius: 18) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Sensor.allCases) { s in
                    let isOn = store.visibleSensors.contains(s)
                    Button { withAnimation(.snappy) { store.toggle(s) } } label: {
                        HStack(spacing: 8) {
                            SensorGlyph(sensor: s)
                            Text(s.rawValue).font(.body(13, .semibold))
                            Text(s.nominalResolution).font(.body(12)).foregroundStyle(Theme.ink2)
                            Spacer(minLength: 8)
                            Text(store.shownCount(s).grouped).font(.body(13, .semibold)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .opacity(isOn ? 1 : 0.4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("\(isOn ? "Hide" : "Show") \(s.rawValue) (\(s == .modis ? "⌘1" : "⌘2"))")
                    .accessibilityLabel("\(s.rawValue), \(store.count(s)) detections, \(isOn ? "shown" : "hidden")")
                }
                if store.mlFilter {
                    Text("Wildfire filter is on").font(.body(12, .semibold)).foregroundStyle(Theme.teal)
                        .help("Showing only detections the harmonized MODIS + VIIRS model classifies as wildfire (⌘3)")
                }
                Divide()
                HStack(alignment: .center, spacing: 5) {
                    ForEach([1.0, 10, 100, 1000], id: \.self) { frp in
                        let r = SensorPalette.radius(frp: frp)
                        Circle().strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1).frame(width: r * 2, height: r * 2)
                    }
                    Spacer(minLength: 6)
                    Text("1 to 1,000 MW").font(.body(11.5)).foregroundStyle(Theme.ink2)
                }
                .frame(height: 24)
                .help("Marker size shows fire radiative power on a log scale")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Marker size shows fire radiative power, from 1 to 1,000 megawatts, on a log scale")
            }
        }
        .frame(width: 236)
    }
}

// MARK: - Timeline

/// Detections per hour (UTC) with MODIS drawn upward and VIIRS drawn downward from a
/// shared baseline, so the two sensors can be compared overpass by overpass.
/// The header also shows the coordinate under the mouse pointer.
struct TimelineCard: View {
    let store: FireStore
    let cursor: CLLocationCoordinate2D?
    @State private var hovered: HourBin?

    var body: some View {
        Card(padding: 13, radius: 20) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Detections per hour, UTC").font(.body(13, .semibold))
                    if let h = hovered {
                        Text("\(Self.hourLabel(h.hour)): \(h.modis) MODIS, \(h.viirs) VIIRS")
                            .font(.body(12.5)).foregroundStyle(Theme.ink2).fixedSize().transition(.opacity)
                    } else {
                        HStack(spacing: 12) {
                            HStack(spacing: 5) { SensorGlyph(sensor: .modis, size: 9); Text("MODIS above") }
                            HStack(spacing: 5) { SensorGlyph(sensor: .viirs, size: 9); Text("VIIRS below") }
                        }
                        .font(.body(12.5)).foregroundStyle(Theme.ink2).transition(.opacity)
                    }
                    Spacer(minLength: 12)
                    Text(cursor.map { coordinateText($0.latitude, $0.longitude, digits: 3) } ?? "")
                        .font(.mono(11)).foregroundStyle(Theme.ink2)
                        .frame(minWidth: 150, alignment: .trailing)
                        .accessibilityLabel("Pointer position")
                }
                .lineLimit(1)
                .animation(.easeOut(duration: 0.12), value: hovered)

                DarkInset {
                    TimelineChart(store: store, hovered: $hovered)
                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: 860)
    }

    /// "Nov 7, 15:00" (the hour that starts then), always in UTC and on a 24-hour clock.
    private static func hourLabel(_ hour: Date) -> String {
        let h = FireQuery.utc.component(.hour, from: hour)
        let day = hour.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
        return String(format: "%@, %02d:00", day, h)
    }
}

/// How many detections each sensor made in one UTC hour.
struct HourBin: Identifiable, Equatable {
    let hour: Date
    var modis = 0
    var viirs = 0
    var id: Date { hour }
}

/// The mirrored bar chart. It is its own view so that moving the mouse over the map
/// (which updates the pointer readout) doesn't redo the counting.
private struct TimelineChart: View {
    let store: FireStore
    @Binding var hovered: HourBin?
    @State private var bins: [HourBin] = []
    @State private var selection: Date?

    private static let grid = Color.white.opacity(0.10)
    private static let label = Theme.onDark.opacity(0.62)

    var body: some View {
        Group {
            if bins.isEmpty {
                Text(store.detections.isEmpty ? "No detections loaded yet"
                     : store.mlFilter ? "The model classified none of these detections as wildfire."
                     : "No detections to plot. Both sensors are hidden.")
                    .font(.body(12.5))
                    .foregroundStyle(Self.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
        .frame(height: 92)
        .onChange(of: store.displayKey, initial: true) {
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
                AxisGridLine().foregroundStyle(isMidnight ? Color.white.opacity(0.24) : Self.grid)
                AxisValueLabel(centered: false) {
                    // Midnight ticks show the date. The others show the UTC hour.
                    if let date {
                        Text(isMidnight ? date.formatted(Self.dayFormat)
                                        : String(format: "%02d:00", FireQuery.utc.component(.hour, from: date)))
                            .font(.body(10, isMidnight ? .bold : .medium))
                            .foregroundStyle(isMidnight ? Theme.onDark : Self.label)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel {
                    // VIIRS counts are plotted below zero, so show the size without the minus sign.
                    if let v = value.as(Int.self) { Text(abs(v).grouped) }
                }
                .font(.body(10))
                .foregroundStyle(Self.label)
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
        var byHour: [Int: HourBin] = [:]
        for d in detections {
            guard let t = d.acquiredAt else { continue }
            let key = Int((t.timeIntervalSince1970 / 3600).rounded(.down))
            var bin = byHour[key] ?? HourBin(hour: Date(timeIntervalSince1970: Double(key) * 3600))
            if d.sensor == .modis { bin.modis += 1 } else { bin.viirs += 1 }
            byHour[key] = bin
        }
        return byHour.values.sorted { $0.hour < $1.hour }
    }
}
