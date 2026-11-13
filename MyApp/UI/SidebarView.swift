//  SidebarView.swift
//  The left column. From top to bottom: brand header, the MODIS vs VIIRS comparison
//  (counts, on/off toggles, and side-by-side statistics), the area and date controls,
//  the data pipeline, and a status footer.
//
//  The overpass timeline lives on the map (see TimelineDock in MapHUD.swift), where it has room.

import SwiftUI
import AppKit

struct SidebarView: View {
    @Bindable var store: FireStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader()
                ViewModeSection(store: store)
                SectionRule()
                ComparisonSection(store: store)
                SectionRule()
                QuerySection(store: store)
                SectionRule()
                PipelineSection(store: store)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(store: store) }
        .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
    }
}

// MARK: - Brand

/// The app's real icon (the same one shown in the Dock) next to its name.
private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Ember")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.2)
                Text("Active fire detection")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -4)   // The icon image has a little empty space around it.
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - View mode

/// MODIS only / VIIRS only / both raw / harmonized ML. The ML option shows both sensors and
/// hides detections the random forest judges not to be wildfire.
private struct ViewModeSection: View {
    @Bindable var store: FireStore

    var body: some View {
        SidebarSection("Show") {
            EmptyView()
        } content: {
            Picker("Show", selection: Binding(get: { store.displayMode },
                                              set: { m in withAnimation(.snappy) { store.displayMode = m } })) {
                ForEach(DisplayMode.allCases) { m in
                    Text(m.shortLabel).tag(m)
                        .selectionDisabled(m == .wildfireML && !WildfireClassifier.isAvailable)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("⌘1 / ⌘2 toggle each sensor · ⌘3 harmonized ML filter")

            Text(store.displayMode.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.mlFilter ? Theme.ember : Theme.textSecondary)

            if store.mlFilter {
                MLSummary(store: store)
            } else if !WildfireClassifier.isAvailable {
                Text("ML model file (ember_rf.bin) is missing from the app bundle.")
                    .font(.footnoteSmall).foregroundStyle(Theme.danger)
            }
        }
    }
}

private struct MLSummary: View {
    let store: FireStore

    var body: some View {
        let total = store.detections.count
        let kept = store.wildfireCount
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stat("Wildfire", kept, Theme.ember)
                stat("Filtered out", total - kept, Theme.textSecondary)
            }
            if total > 0 {
                MeterBar(fraction: Double(kept) / Double(total),
                         fill: LinearGradient(colors: [Theme.emberHot, Theme.ember], startPoint: .leading, endPoint: .trailing),
                         height: 4)
            }
            sensitivity
            Text("Random forest on harmonized MODIS + VIIRS data: one brightness, FRP-per-km² and confidence scale; cross-sensor confirmation; day/night persistence; NLCD land cover; and 2017–2019 burn history. Filtered out = likely farm or prescribed burns, industrial heat, or false alarms. Trained on California 2020. \(WildfireClassifier.testSummary).")
                .font(.footnoteSmall)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sensitivity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HUDLabel("Sensitivity")
                Spacer()
                Text(String(format: "cut %.2f%@", store.mlThreshold,
                            abs(store.mlThreshold - WildfireClassifier.threshold) < 0.001 ? " (default)" : ""))
                    .font(.mono(10)).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: Binding(get: { Double(store.mlThreshold) }, set: { store.mlThreshold = Float($0) }),
                   in: 0.2...0.8, step: 0.05)
                .controlSize(.small)
                .tint(Theme.ember)
            HStack {
                Text("Catch more small fires")
                Spacer()
                Text("Fewer false alarms")
            }
            .font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
        }
        .help("Probability needed to call a detection a wildfire. The default (0.30) was chosen by cross-validation on 2020-2023. On 2024, never seen in training, 0.30 caught 186 of 205 fires and removed 86% of non-wildfire detections; 0.60 caught 168 and removed 94%.")
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HUDLabel(label)
            Text(n.grouped).font(.hudNumber(20)).foregroundStyle(color)
                .contentTransition(.numericText(value: Double(n)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sensor comparison

/// The numbers shown for one sensor. Everything is computed from the detections exactly as FIRMS reported them.
private struct SensorStats {
    var count = 0
    var medianFRP: Double?
    var peakFRP: Double?
    var highConfidence = 0
    var night = 0

    init(_ detections: [FireDetection], sensor: Sensor) {
        var frps: [Double] = []
        for d in detections where d.sensor == sensor {
            count += 1
            if let f = d.frp { frps.append(f) }
            if d.dayNight == .night { night += 1 }
            switch d.confidence {
            case .percent(let p): if p >= 80 { highConfidence += 1 }
            case .category(let c): if c == .high { highConfidence += 1 }
            case .unknown: break
            }
        }
        frps.sort()
        peakFRP = frps.last
        medianFRP = frps.isEmpty ? nil : frps[frps.count / 2]
    }

    func share(_ n: Int) -> String {
        count == 0 ? "—" : "\(Int((Double(n) / Double(count) * 100).rounded()))%"
    }
}

private struct ComparisonSection: View {
    let store: FireStore

    var body: some View {
        let modis = SensorStats(store.detections, sensor: .modis)
        let viirs = SensorStats(store.detections, sensor: .viirs)
        let q = store.loadedQuery ?? store.query

        SidebarSection("MODIS vs VIIRS") {
            Text("\((modis.count + viirs.count).grouped) total")
                .font(.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.numericText())
        } content: {
            HStack(spacing: 8) {
                SensorTile(sensor: .modis, count: modis.count, subtitle: "Terra + Aqua · 1 km",
                           isOn: store.visibleSensors.contains(.modis), shortcut: "⌘1") {
                    withAnimation(.snappy) { store.toggle(.modis) }
                }
                SensorTile(sensor: .viirs, count: viirs.count, subtitle: "\(q.viirsSatellite.label) · 375 m",
                           isOn: store.visibleSensors.contains(.viirs), shortcut: "⌘2") {
                    withAnimation(.snappy) { store.toggle(.viirs) }
                }
            }

            SplitBar(modis: modis.count, viirs: viirs.count)

            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    columnHeader(.modis)
                    columnHeader(.viirs)
                }
                row("Median FRP", frp(modis.medianFRP), frp(viirs.medianFRP))
                row("Peak FRP", frp(modis.peakFRP), frp(viirs.peakFRP))
                row("High confidence", modis.share(modis.highConfidence), viirs.share(viirs.highConfidence))
                row("Night-time", modis.share(modis.night), viirs.share(viirs.night))
            }
            .padding(.top, 2)

            Text("High confidence means MODIS ≥ 80% or VIIRS “high”. These numbers describe the data. Nothing is filtered out.")
                .font(.footnoteSmall)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func frp(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: v >= 100 ? "%.0f MW" : "%.1f MW", v)
    }

    private func columnHeader(_ s: Sensor) -> some View {
        HStack(spacing: 4) {
            SensorGlyph(sensor: s, size: 6, glow: false)
            Text(s.rawValue).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textSecondary)
        }
    }

    private func row(_ label: String, _ m: String, _ v: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(m).font(.mono).foregroundStyle(Theme.modis)
            Text(v).font(.mono).foregroundStyle(Theme.viirs)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .contentTransition(.numericText())
    }
}

/// A sensor's count. Click it to show or hide that sensor on the map.
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SensorGlyph(sensor: sensor, size: 9, glow: isOn)
                    Text(sensor.rawValue)
                        .font(.wide(10.5))
                        .tracking(1.2)
                    Spacer(minLength: 0)
                    Image(systemName: isOn ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOn ? c : Theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(count.grouped)
                    .font(.hudNumber(27))
                    .foregroundStyle(isOn ? c : Theme.textSecondary)
                    .contentTransition(.numericText(value: Double(count)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [c.opacity(isOn ? 0.20 : 0.03), c.opacity(isOn ? 0.05 : 0.01)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isOn ? c.opacity(hovering ? 0.9 : 0.42) : Color.white.opacity(hovering ? 0.25 : 0.10), lineWidth: 1)
            }
            .opacity(isOn ? 1 : 0.6)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(isOn ? "Hide" : "Show") \(sensor.rawValue) detections (\(shortcut))")
        .accessibilityLabel("\(sensor.rawValue), \(count) detections, \(isOn ? "shown" : "hidden")")
    }
}

/// A thin bar showing how the detections split between MODIS and VIIRS.
private struct SplitBar: View {
    let modis: Int
    let viirs: Int

    var body: some View {
        let total = modis + viirs
        GeometryReader { g in
            let f = total == 0 ? 0.5 : CGFloat(modis) / CGFloat(total)
            HStack(spacing: 2) {
                Capsule().fill(Theme.modis).frame(width: max(3, (g.size.width - 2) * f))
                Capsule().fill(Theme.viirs).frame(minWidth: 3)
            }
            .opacity(total == 0 ? 0.2 : 1)
        }
        .frame(height: 4)
        .accessibilityLabel("MODIS \(modis), VIIRS \(viirs)")
    }
}

// MARK: - Query controls

private struct QuerySection: View {
    @Bindable var store: FireStore

    var body: some View {
        SidebarSection("Area & time") {
            if store.queryIsDirty {
                Text("NOT FETCHED YET").font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.ember.opacity(0.18), in: .capsule)
                    .foregroundStyle(Theme.ember)
                    .help("These settings differ from the data on the map. Press Fetch Detections to download them.")
            }
        } content: {
            Menu {
                ForEach(AreaPreset.all) { p in
                    Button(p.name) { store.selectPreset(p) }
                }
                if store.visibleMapBounds != nil {
                    Divider()
                    Button("Use Visible Map Area") { store.useVisibleMapArea() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(Theme.ember)
                    Text(store.query.areaName).fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .card(radius: 9)
                .contentShape(.rect(cornerRadius: 9))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Area: \(store.query.areaName)")

            BoundsEditor(bounds: $store.query.bounds, onEdit: { store.query.areaName = "Custom area" })

            HStack(spacing: 6) {
                Button { store.useVisibleMapArea() } label: { Label("Use Visible Map", systemImage: "viewfinder") }
                    .disabled(store.visibleMapBounds == nil)
                    .help("Set the area to what the map is showing now")
                Button { store.zoomToArea() } label: { Label("Zoom to Area", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Zoom the map to this area (⌘0)")
            }
            .buttonStyle(QuietButtonStyle())

            if let err = store.query.bounds.validationError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }

            VStack(spacing: 8) {
                // FIRMS works in UTC days, so the picker shows UTC.
                FormRow("Start date (UTC)") {
                    DatePicker("Start date", selection: $store.query.startDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                }
                FormRow("Days") {
                    Stepper(value: $store.query.dayCount, in: 1...FireQuery.maxDayCount) {
                        Text("\(store.query.dayCount)").font(.mono(12, .semibold)).monospacedDigit()
                    }
                }
                FormRow("Product") {
                    Picker("Product", selection: $store.query.product) {
                        Text("Near real-time").tag(FIRMSProduct.nearRealTime)
                        Text("Archive").tag(FIRMSProduct.standard)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Near real-time arrives within about 3 hours. Archive is reprocessed, science-quality data and lags by a few months.")
                }
                FormRow("VIIRS satellite") {
                    Picker("VIIRS satellite", selection: $store.query.viirsSatellite) {
                        ForEach(VIIRSSatellite.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.top, 2)
            .tint(.white)

            if store.query.viirsSatellite == .suomiNPP {
                Label("Suomi NPP stopped delivering new fire data on Nov 2, 2026. Use earlier dates, or choose NOAA-20/21 for recent fires.",
                      systemImage: "info.circle.fill")
                    .font(.footnoteSmall)
                    .foregroundStyle(Theme.modis)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RequestSummary(query: store.query)

            Button { store.refresh() } label: {
                Label(store.isLoading ? "Fetching…" : "Fetch Detections", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(EmberButtonStyle())
            .disabled(store.isLoading || store.query.bounds.validationError != nil)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Download detections for this area and these dates (⌘↩)")
        }
    }
}

/// A label on the left and a control on the right.
private struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            content
        }
        .frame(minHeight: 22)
    }
}

/// Spells out exactly what will be requested from FIRMS.
private struct RequestSummary: View {
    let query: FireQuery

    var body: some View {
        let requests = query.dayChunks.count * 2
        VStack(alignment: .leading, spacing: 3) {
            Text("\(FireQuery.firmsDateString(query.startDate)) → \(FireQuery.firmsDateString(query.endDate)) · \(requests) request\(requests == 1 ? "" : "s")")
            Text("\(query.modisSource) + \(query.viirsSource)")
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.mono(10))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        .textSelection(.enabled)
        .help("FIRMS allows 5 days per request, so longer ranges are split into several requests for each sensor.")
    }
}

/// Four number fields: west and east on the first row, south and north on the second.
private struct BoundsEditor: View {
    @Binding var bounds: GeoBounds
    var onEdit: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                field("W", "West longitude", \.west)
                field("E", "East longitude", \.east)
            }
            GridRow {
                field("S", "South latitude", \.south)
                field("N", "North latitude", \.north)
            }
        }
    }

    private func field(_ label: String, _ name: String, _ kp: WritableKeyPath<GeoBounds, Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
            TextField(name, value: Binding(get: { bounds[keyPath: kp] },
                                           set: { bounds[keyPath: kp] = $0; onEdit() }),
                      format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.plain)
                .font(.mono(12))
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(name)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .card(radius: 8)
    }
}

// MARK: - Pipeline

/// Shows the data flow and where a future processing step will go.
private struct PipelineSection: View {
    let store: FireStore

    var body: some View {
        SidebarSection("Data pipeline") {
            HStack(spacing: 5) {
                chip("Download")
                arrow
                chip("Parse")
                arrow
                ForEach(store.pipeline.steps, id: \.name) { step in
                    chip(step.name, highlight: true)
                    arrow
                }
                if store.mlFilter {
                    chip("ML filter", highlight: true)
                    arrow
                }
                chip("Map")
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Text(store.mlFilter
                 ? "The ML filter only changes what the map shows. Cache and CSV export keep every detection exactly as FIRMS reported it."
                 : "Every detection is shown exactly as FIRMS reported it. Processing steps are added in DetectionProcessor.swift.")
                .font(.footnoteSmall)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if store.skippedRows > 0 {
                Label("\(store.skippedRows) rows skipped (invalid coordinates)", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(Theme.modis)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(highlight ? Theme.ember.opacity(0.14) : Theme.panelRaised, in: .capsule)
            .overlay(Capsule().strokeBorder(highlight ? Theme.ember.opacity(0.55) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(highlight ? Theme.ember : Theme.textSecondary)
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    let store: FireStore

    var body: some View {
        HStack(spacing: 9) {
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
                    Text(updated.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)

            Spacer()

            if store.lastUpdated != nil, !store.isLoading {
                Text(store.isShowingCachedData ? "CACHED" : "LIVE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(statusColor)
                    .overlay(Capsule().strokeBorder(statusColor.opacity(0.5)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { SectionRule() }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if store.isLoading { return Theme.viirs }
        if store.error != nil { return Theme.danger }
        if store.isShowingCachedData { return Theme.modis }
        return store.lastUpdated == nil ? .gray : Theme.ok
    }
}
