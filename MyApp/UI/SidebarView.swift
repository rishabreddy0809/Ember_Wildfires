//  SidebarView.swift
//  The left column. From top to bottom: what was downloaded (click it to change the area
//  and dates), which detections to show, the wildfire filter's sensitivity, and the list
//  of regions that are burning, busiest first.

import SwiftUI

struct SidebarView: View {
    @Bindable var store: FireStore
    @State private var editing = false

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Fire data").font(.body(13, .semibold))
                    RequestCard(store: store, editing: $editing)
                    if store.queryIsDirty {
                        HStack(spacing: 6) {
                            Text("Changed, not downloaded yet.").font(.body(12)).foregroundStyle(Theme.ink2)
                            LinkButton(title: "Download now") { store.refresh() }
                        }
                    }
                    Divide()
                    ShowSection(store: store)
                    Divide()
                    HStack(alignment: .firstTextBaseline) {
                        Text("Where it's burning").font(.body(13, .semibold))
                        Spacer()
                        Text("\(store.visibleRegions.count) of \(store.regions.count)").font(.body(12)).foregroundStyle(Theme.ink2)
                    }
                    SearchField(text: $store.regionSearch, prompt: "Search regions")
                }
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

                RegionList(store: store)
                StatusFooter(store: store)
            }
        }
    }
}

// MARK: - Request

/// What was asked of FIRMS. Opens the editor for the area, the dates and the sources.
private struct RequestCard: View {
    @Bindable var store: FireStore
    @Binding var editing: Bool

    var body: some View {
        let q = store.query
        Button { editing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: q.bounds.isWorld ? "globe.europe.africa.fill" : "scope")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.onDark)
                    .frame(width: 38, height: 38).background(Theme.navy, in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(q.areaName).font(.serif(23)).lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(dateRangeText(q)) · \(q.viirsSatellite.label)").font(.body(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink2)
            }
            .padding(12)
            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Change the area, the dates, or the satellite")
        .accessibilityLabel("Area: \(q.areaName), \(dateRangeText(q))")
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            RequestEditor(store: store) { editing = false }
        }
    }
}

/// The area, date and source controls, and the button that downloads.
private struct RequestEditor: View {
    @Bindable var store: FireStore
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What to download").font(.serif(26))

            VStack(alignment: .leading, spacing: 8) {
                Text("Area").font(.body(13, .semibold))
                Menu {
                    ForEach(AreaPreset.all) { p in Button(p.name) { store.selectPreset(p) } }
                    if store.visibleMapBounds != nil {
                        Divider()
                        Button("Use the area the map is showing") { store.useVisibleMapArea() }
                    }
                } label: {
                    HStack {
                        Text(store.query.areaName).font(.body(13, .semibold))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink2)
                    }
                    .padding(.horizontal, 11).frame(height: 32)
                    .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain)
                BoundsEditor(bounds: $store.query.bounds) { store.query.areaName = "Custom area" }
                if let problem = store.query.bounds.validationError {
                    Text(problem).font(.body(12)).foregroundStyle(Theme.poor)
                }
            }

            Divide()

            VStack(spacing: 8) {
                // FIRMS works in UTC days, so the picker shows UTC.
                row("First day (UTC)") {
                    DatePicker("First day", selection: $store.query.startDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field)
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                }
                row("Days") {
                    Stepper(value: $store.query.dayCount, in: 1...FireQuery.maxDayCount) {
                        Text("\(store.query.dayCount)").font(.body(13, .semibold)).monospacedDigit()
                    }
                }
                row("Data") {
                    Picker("Data", selection: $store.query.product) {
                        Text("Near real-time").tag(FIRMSProduct.nearRealTime)
                        Text("Archive").tag(FIRMSProduct.standard)
                    }
                    .labelsHidden().fixedSize()
                    .help("Near real-time arrives within about 3 hours. Archive is reprocessed, science-quality data and lags by a few months.")
                }
                row("VIIRS satellite") {
                    Picker("VIIRS satellite", selection: $store.query.viirsSatellite) {
                        ForEach(VIIRSSatellite.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            if store.query.viirsSatellite == .suomiNPP {
                Text("Suomi NPP stopped delivering new fire data on Nov 2, 2026. Use earlier dates, or choose NOAA-20 or NOAA-21 for recent fires.")
                    .font(.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }

            let requests = store.query.dayChunks.count * 2
            Text("\(store.query.modisSource) + \(store.query.viirsSource), \(requests) request\(requests == 1 ? "" : "s"). A whole-world day is roughly 50,000 detections.")
                .font(.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                .help("FIRMS allows 5 days per request, so longer ranges are split into several requests for each sensor.")

            ActionButton(title: store.isLoading ? "Downloading…" : "Download detections") {
                store.refresh()
                close()
            }
            .disabled(store.isLoading || store.query.bounds.validationError != nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(20)
        .frame(width: 340)
        .foregroundStyle(Theme.ink)
        .background(Theme.cream0)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(.body(13)).foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: 24)
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
            Text(label).font(.body(11, .bold)).foregroundStyle(Theme.ink3)
            TextField(name, value: Binding(get: { bounds[keyPath: kp] },
                                           set: { bounds[keyPath: kp] = $0; onEdit() }),
                      format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.plain).font(.mono(12)).multilineTextAlignment(.trailing)
                .accessibilityLabel(name)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

// MARK: - Show

/// Both sensors, one sensor, or only what the model classifies as wildfire.
private struct ShowSection: View {
    let store: FireStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Show").font(.body(13, .semibold))
                Spacer()
                Text("\(store.world.count.grouped) shown").font(.body(12)).foregroundStyle(Theme.ink2)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 5) {
                ForEach(DisplayMode.allCases) { m in
                    PillTab(m.shortLabel, selected: store.displayMode == m, compact: true) {
                        withAnimation(.snappy) { store.displayMode = m }
                    }
                    .disabled(m == .wildfireML && !WildfireClassifier.isAvailable)
                }
            }
            .help("⌘1 and ⌘2 switch each sensor on and off. ⌘3 switches the wildfire filter.")

            if store.mlFilter {
                HStack(alignment: .firstTextBaseline) {
                    Text("Filter sensitivity").font(.body(13, .semibold))
                    Spacer()
                    Text(String(format: "%.0f%%", store.mlThreshold * 100)).font(.body(13)).foregroundStyle(Theme.ink2)
                }
                .padding(.top, 2)
                PaperSlider(value: Binding(get: { Double(store.mlThreshold) }, set: { store.setThreshold(Float($0)) }),
                            range: 0.2...0.8)
                    .accessibilityLabel("Filter sensitivity")
                Text("How sure the model must be to keep a detection. Slide left to catch more small fires, right for fewer false alarms.")
                    .font(.body(12)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(caption).font(.body(12)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var caption: String {
        if !WildfireClassifier.isAvailable { return "The wildfire model file (ember_rf.bin) is missing from the app." }
        switch store.displayMode {
        case .both: return "Every detection from both sensors, exactly as FIRMS reported it."
        case .modis: return "MODIS only: Terra and Aqua, 1 km pixels."
        case .viirs: return "VIIRS only: 375 m pixels, about seven times finer than MODIS."
        case .wildfireML: return ""
        }
    }
}

// MARK: - Regions

private struct RegionList: View {
    let store: FireStore

    var body: some View {
        let list = store.visibleRegions
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(list) { r in
                    Button { store.selectRegion(r) } label: {
                        RegionRow(region: r, selected: store.selectedRegionID == r.id)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                if list.isEmpty {
                    Text(store.regions.isEmpty ? (store.isLoading ? "Downloading…" : "No detections to list.") : "No region matches.")
                        .font(.body(12.5)).foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }
}

private struct RegionRow: View {
    let region: RegionSummary
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusIcon(color: region.activity.color, symbol: region.activity.symbol, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(region.name).font(.body(13.5, .semibold)).lineLimit(1)
                Text("\(region.continent) · peak \(megawatts(region.peakFRP))").font(.body(12))
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(region.count.grouped).font(.serif(25)).monospacedDigit().contentTransition(.numericText())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(selected ? .white : Theme.ink)
        .background(selected ? Theme.tealDark : (hover ? Theme.chip : .clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(region.name), \(region.count) detections, \(region.activity.rawValue)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    let store: FireStore

    var body: some View {
        VStack(spacing: 0) {
            Divide()
            HStack(spacing: 8) {
                Circle().fill(color).overlay(Circle().strokeBorder(Theme.ink.opacity(0.6), lineWidth: 1)).frame(width: 10, height: 10)
                Group {
                    if store.isLoading {
                        Text(store.loadingStatus.isEmpty ? "Working…" : store.loadingStatus)
                    } else if let updated = store.lastUpdated {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("Updated \(updated, format: .relative(presentation: .named))")
                        }
                    } else {
                        Text("No data yet")
                    }
                }
                .font(.body(12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer()
                if store.lastUpdated != nil, !store.isLoading {
                    Text(store.isShowingCachedData ? "Saved copy" : "Live")
                        .font(.body(11.5, .semibold))
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(store.isShowingCachedData ? Theme.fair.opacity(0.45) : Theme.mint, in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if store.isLoading { return Theme.viirs }
        if store.error != nil { return Theme.poor }
        if store.isShowingCachedData { return Theme.fair }
        return store.lastUpdated == nil ? Theme.ink3 : Theme.good
    }
}
