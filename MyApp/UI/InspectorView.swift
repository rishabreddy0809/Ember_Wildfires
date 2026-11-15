//  InspectorView.swift
//  The right-hand card. It always has something to say:
//  • a detection is selected: every value FIRMS reported for it, and the model's verdict;
//  • a region is selected: its totals and its strongest fires;
//  • nothing is selected: the totals for everything on screen.
//  If a click landed on overlapping detections, a pager steps through all of them.
//  They are listed one by one and never merged.

import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var store: FireStore

    var body: some View {
        Card(padding: 0) {
            Group {
                if let d = store.selected {
                    ScrollView {
                        DetectionDetail(d: d, store: store).padding(20)
                    }
                    .id(d.id)
                } else if let r = store.selectedRegion {
                    ScrollView {
                        SummaryDetail(s: r, isWorld: false, store: store).padding(20)
                    }
                    .id("region-" + r.id)
                } else {
                    ScrollView {
                        SummaryDetail(s: store.world, isWorld: true, store: store).padding(20)
                    }
                    .id("world")
                }
            }
            .defaultScrollAnchor(.top)
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - One detection

private struct DetectionDetail: View {
    let d: FireDetection
    let store: FireStore

    var body: some View {
        let probability = store.wildfireProbability(d)
        VStack(alignment: .leading, spacing: 16) {
            if store.selectionStack.count > 1 { StackPager(store: store) }

            HStack(alignment: .top, spacing: 10) {
                Text("\(d.sensor.rawValue)\ndetection").font(.serif(40)).lineSpacing(-6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if probability != nil {
                    if store.isWildfire(d) {
                        StatusBadge(text: "Wildfire", color: Theme.poor, symbol: "flame.fill")
                    } else {
                        StatusBadge(text: "Not wildfire", color: Theme.chip, symbol: "minus")
                    }
                }
            }
            Text("\(store.regionName(of: d)). \(coordinateText(d.latitude, d.longitude, digits: 4))")
                .font(.body(13)).foregroundStyle(Theme.ink2).textSelection(.enabled)
                .padding(.top, -8)

            sentence

            Divide()
            HStack(alignment: .top, spacing: 12) {
                BigStat(label: "Fire power", value: frpValue, caption: "Megawatts of heat the fire radiates.", size: 40)
                BigStat(label: "Brightness", value: d.brightness.map { String(format: "%.0f K", $0) } ?? "—",
                        caption: d.sensor == .modis ? "Temperature seen at 4 µm." : "Temperature seen at 3.7 µm.", size: 40)
                BigStat(label: "Confidence", value: d.confidence.displayText,
                        caption: d.sensor == .modis ? "MODIS reports 0 to 100%." : "VIIRS reports low, nominal or high.", size: 40)
            }
            Divide()

            if let p = probability {
                VStack(alignment: .leading, spacing: 7) {
                    (Text("Wildfire probability: ").font(.body(14))
                     + Text("\(Int((p * 100).rounded()))%").font(.body(14, .bold))
                     + Text(", \(p >= store.mlThreshold ? "above" : "below") the \(Int((store.mlThreshold * 100).rounded()))% cut.").font(.body(14)))
                    Bar(value: Double(p), tint: p >= store.mlThreshold ? Theme.poor : Theme.ink3)
                    Text("Not wildfire usually means a farm or prescribed burn, an industrial heat source, or a false alarm. The model was trained on California, so treat it as a guide elsewhere.")
                        .font(.body(12)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("As reported").font(.body(13, .semibold)).padding(.bottom, 4)
                Divide()
                FactRow(label: "Satellite", value: d.satelliteName)
                FactRow(label: "Seen at", value: "\(d.acqDate) \(d.acqTime.prefix(2)):\(d.acqTime.suffix(2)) UTC")
                FactRow(label: "Day or night", value: d.dayNight.label)
                FactRow(label: "Pixel size", value: footprint)
                FactRow(label: "Second channel", value: d.brightness2.map { String(format: "%.1f K", $0) } ?? "—")
                FactRow(label: "Source", value: d.source)
                FactRow(label: "Version", value: d.version)
                if let t = d.type { FactRow(label: "Type", value: typeName(t)) }
            }

            DarkInset {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every FIRMS column, unchanged").font(.body(12.5, .semibold)).foregroundStyle(Theme.onDark)
                    VStack(spacing: 3) {
                        ForEach(Array(d.allColumns.enumerated()), id: \.offset) { _, col in
                            HStack {
                                Text(col.name).foregroundStyle(Theme.onDark.opacity(0.6))
                                Spacer()
                                Text(col.value.isEmpty ? "∅" : col.value).foregroundStyle(Theme.onDark).textSelection(.enabled)
                            }
                            .font(.mono(11, .regular))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                ActionButton(title: store.mode == .map ? "Center on map" : "Open on map") {
                    store.mode = .map
                    store.focus(on: d)
                }
                ActionButton(title: "Copy coordinates", primary: false) {
                    copy(String(format: "%.5f, %.5f", d.latitude, d.longitude))
                }
            }
            HStack(spacing: 18) {
                LinkButton(title: "Copy row as CSV") {
                    copy(d.allColumns.map(\.name).joined(separator: ",") + "\n" + d.allColumns.map(\.value).joined(separator: ","))
                }
                LinkButton(title: "Clear selection") { store.clearSelection() }
            }
        }
    }

    private var frpValue: String {
        guard let f = d.frp else { return "—" }
        return String(format: f >= 100 ? "%.0f" : "%.1f", f)
    }

    private var sentence: some View {
        let when: String = {
            guard let t = d.acquiredAt else { return "" }
            return " " + t.formatted(.relative(presentation: .named)) + "."
        }()
        let time = d.dayNight == .night ? "at night" : (d.dayNight == .day ? "in daylight" : "")
        return (Text("Seen by \(d.satelliteName) \(time).").font(.body(15, .semibold))
                + Text("\(when) One \(d.sensor.nominalResolution) pixel flagged as burning; the fire is somewhere inside it.")
                    .font(.body(15)).foregroundStyle(Theme.ink2))
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    private var footprint: String {
        guard let s = d.scan, let t = d.track else { return "—" }
        return String(format: "%.2f × %.2f km", s, t)
    }

    private func typeName(_ t: Int) -> String {
        switch t {
        case 0: "Vegetation fire"
        case 1: "Active volcano"
        case 2: "Other static land source"
        case 3: "Offshore"
        default: "Unknown (\(t))"
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Steps through the detections that were under one click.
private struct StackPager: View {
    let store: FireStore
    var body: some View {
        HStack(spacing: 10) {
            pagerButton("chevron.left", "Previous detection") { store.stepSelection(-1) }
                .keyboardShortcut("[", modifiers: [])
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.selectionIndex + 1) of \(store.selectionStack.count) under the click").font(.body(12.5, .semibold))
                HStack(spacing: 3) {
                    // A window of dots around the current one, so the row never outgrows the card.
                    let first = max(0, min(store.selectionIndex - 7, store.selectionStack.count - 15))
                    ForEach(Array(store.selectionStack.enumerated()).dropFirst(first).prefix(15), id: \.element.id) { i, d in
                        SensorGlyph(sensor: d.sensor, size: i == store.selectionIndex ? 10 : 7)
                            .frame(width: 10, height: 10)
                            .onTapGesture { store.selectionIndex = i }
                    }
                }
            }
            Spacer(minLength: 0)
            pagerButton("chevron.right", "Next detection") { store.stepSelection(1) }
                .keyboardShortcut("]", modifiers: [])
        }
        .padding(10)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help("Overlapping detections are kept separate. Use [ and ] to step through them.")
    }

    private func pagerButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 28, height: 28).background(.white.opacity(0.7), in: Circle())
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - A region, or everything

private struct SummaryDetail: View {
    let s: RegionSummary
    let isWorld: Bool
    let store: FireStore

    var body: some View {
        let q = store.loadedQuery ?? store.query
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Text(s.name.isEmpty ? q.areaName : s.name).font(.serif(40)).lineSpacing(-6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !isWorld { StatusBadge(text: s.activity.rawValue, color: s.activity.color, symbol: s.activity.symbol) }
            }
            Text(isWorld ? "\(dateRangeText(q)). \(store.regions.count) regions with fire."
                         : "\(s.continent). Fires centred near \(coordinateText(s.latitude, s.longitude, digits: 1)).")
                .font(.body(13)).foregroundStyle(Theme.ink2)
                .padding(.top, -8)

            if s.count == 0 {
                Text(store.isLoading ? "Downloading the latest detections…" : "Nothing to show yet. Download detections, or widen what is shown.")
                    .font(.body(15)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                sentence(q)

                Divide()
                HStack(alignment: .top, spacing: 12) {
                    BigStat(label: "Detections", value: compact(s.count), caption: "Satellite pixels flagged as burning.", size: 40)
                    BigStat(label: "Strongest", value: s.peakFRP >= 1000 ? String(format: "%.1fk", s.peakFRP / 1000) : String(format: "%.0f", s.peakFRP),
                            caption: "Megawatts from the hottest pixel.", size: 40)
                    BigStat(label: "Wildfire", value: share(s.wildfire, of: s.scored),
                            caption: "Share the model calls wildfire.", size: 40)
                }
                Divide()

                VStack(alignment: .leading, spacing: 0) {
                    Text("In numbers").font(.body(13, .semibold)).padding(.bottom, 4)
                    Divide()
                    FactRow(label: "MODIS (1 km)", value: s.modis.grouped)
                    FactRow(label: "VIIRS (375 m)", value: s.viirs.grouped)
                    FactRow(label: "Typical fire power", value: megawatts(s.medianFRP))
                    FactRow(label: "All fire power", value: s.totalFRP >= 1000 ? String(format: "%.1f GW", s.totalFRP / 1000) : megawatts(s.totalFRP))
                    FactRow(label: "High confidence", value: share(s.highConfidence, of: s.count))
                    FactRow(label: "Seen at night", value: share(s.night, of: s.count))
                }

                if isWorld {
                    busiest
                } else {
                    DarkInset {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Share of everything shown").font(.body(12.5, .semibold))
                                Spacer()
                                Text(share(s.count, of: store.world.count)).font(.serif(24))
                            }
                            .foregroundStyle(Theme.onDark)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.12))
                                    Capsule().fill(Theme.modis)
                                        .frame(width: max(6, g.size.width * clamp01(Double(s.count) / Double(max(store.world.count, 1)))))
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(14)
                    }
                }

                strongest

                if isWorld {
                    HStack(spacing: 10) {
                        ActionButton(title: "Refresh") { store.refresh() }.disabled(store.isLoading)
                        ActionButton(title: "First region", primary: false) { store.stepRegion(1) }
                    }
                } else {
                    HStack(spacing: 10) {
                        ActionButton(title: store.mode == .map ? "Zoom to region" : "Open on map") {
                            store.mode = .map
                            store.selectRegion(s)
                        }
                        ActionButton(title: "Next region", primary: false) { store.stepRegion(1) }
                    }
                }
                HStack(spacing: 18) {
                    LinkButton(title: "Download CSV") { store.beginExport() }
                    if !isWorld { LinkButton(title: "Back to everything") { store.selectRegion(nil) } }
                }

                Text("Regions are rough boxes for grouping detections, not borders. \"Intense\" means 2,500 or more detections a day, \"Active\" 250 or more.")
                    .font(.body(11.5)).foregroundStyle(Theme.ink3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentence(_ q: FireQuery) -> some View {
        let span = q.dayCount == 1 ? "one day" : "\(q.dayCount) days"
        let lead = isWorld ? "\(s.count.grouped) detections in \(span)." : "\(s.activity.phrase): \(s.count.grouped) detections in \(span)."
        let finer = s.viirs >= s.modis ? "VIIRS" : "MODIS"
        let rest = " \(share(max(s.viirs, s.modis), of: s.count)) came from \(finer), and \(share(s.night, of: s.count)) were seen at night."
        return (Text(lead).font(.body(15, .semibold)) + Text(rest).font(.body(15)).foregroundStyle(Theme.ink2))
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    /// The five busiest regions, each a button.
    private var busiest: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Busiest regions").font(.body(13, .semibold)).padding(.bottom, 4)
            Divide()
            ForEach(store.regions.prefix(5)) { r in
                Button { store.selectRegion(r) } label: {
                    HStack(spacing: 9) {
                        StatusIcon(color: r.activity.color, symbol: r.activity.symbol, size: 16)
                        Text(r.name).font(.body(13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(r.count.grouped).font(.body(13, .semibold)).monospacedDigit()
                    }
                    .padding(.vertical, 8).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                Divide()
            }
        }
    }

    /// The five strongest detections. Click one to select it and bring it into view.
    private var strongest: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Strongest fires").font(.body(13, .semibold)).padding(.bottom, 4)
            Divide()
            ForEach(s.top) { d in
                Button { store.show(d) } label: {
                    HStack(spacing: 9) {
                        SensorGlyph(sensor: d.sensor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(isWorld ? store.regionName(of: d) : coordinateText(d.latitude, d.longitude)).font(.body(13)).lineLimit(1)
                            Text("\(d.acqDate) \(d.acqTime.prefix(2)):\(d.acqTime.suffix(2)) UTC").font(.body(11.5)).foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 8)
                        Text(megawatts(d.frp)).font(.body(13, .semibold)).monospacedDigit()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                Divide()
            }
        }
    }

    /// 84,190 → "84.2k", so three figures fit side by side.
    private func compact(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : n.grouped
    }
}
