//  GlobeTab.swift
//  The Globe view: the 3D Earth with cards floating over it. Top left says how much is
//  burning, top right switches the scene effects, and bottom left names what is selected.

import SwiftUI

struct GlobeTab: View {
    let store: FireStore

    var body: some View {
        ZStack {
            GlobeView(store: store)
            VStack {
                HStack(alignment: .top) {
                    WorldCard(store: store)
                    Spacer()
                    EffectsBar(store: store)
                }
                Spacer()
                StatusNotices(store: store)
                HStack(alignment: .bottom) {
                    SelectionCard(store: store)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) { FireSwatch(colors: [Color(red: 1, green: 0.30, blue: 0.05), Color(red: 1, green: 0.86, blue: 0.46)]); Text("MODIS") }
                            HStack(spacing: 6) { FireSwatch(colors: [Color(red: 0.16, green: 0.52, blue: 1), Color(red: 0.70, green: 0.90, blue: 1)]); Text("VIIRS") }
                            Text("faint → strong").foregroundStyle(Theme.onDark.opacity(0.55))
                        }
                        .font(.body(11.5, .medium)).foregroundStyle(Theme.onDark.opacity(0.85))
                        .help("Orange fires were seen by MODIS, light blue fires by VIIRS. Brighter, paler and larger means more fire power, from 1 to 1,000 MW on a log scale.")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Orange fires were seen by MODIS, light blue fires by VIIRS. Brighter and larger means more fire power.")
                        Text("Drag to turn, scroll to zoom. Point at a fire, then click it.")
                            .font(.body(12)).foregroundStyle(Theme.onDark.opacity(0.6))
                    }
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// How much is burning, in everything that is displayed.
struct WorldCard: View {
    let store: FireStore

    var body: some View {
        let w = store.world
        let q = store.loadedQuery ?? store.query
        Card(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(w.count.grouped).font(.serif(46)).monospacedDigit().contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.mlFilter ? "likely wildfire detections," : "fire detections,")
                        Text("\(q.areaName.lowercased() == "whole world" ? "worldwide" : q.areaName), \(dateRangeText(q))")
                    }
                    .font(.body(12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                HStack(spacing: 14) {
                    HStack(spacing: 6) { SensorGlyph(sensor: .modis); Text("\(w.modis.grouped) MODIS") }
                    HStack(spacing: 6) { SensorGlyph(sensor: .viirs); Text("\(w.viirs.grouped) VIIRS") }
                    if !store.mlFilter, w.scored > 0 {
                        HStack(spacing: 6) {
                            StatusIcon(color: Theme.poor, symbol: "flame.fill", size: 13)
                            Text("\(share(w.wildfire, of: w.scored)) likely wildfire")
                        }
                    }
                }
                .font(.body(12.5)).lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Switches for the globe's shader effects and motion.
struct EffectsBar: View {
    @Bindable var store: FireStore

    var body: some View {
        HStack(spacing: 6) {
            toggle("Clouds", $store.fx.clouds)
            toggle("Grid", $store.fx.grid)
            toggle("Aurora", $store.fx.aurora)
            toggle("Pulse", $store.fx.pulse)
            toggle("Spin", $store.fx.spin)
        }
        .padding(6)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        PillTab(title, selected: on.wrappedValue, onDark: true, compact: true) { on.wrappedValue.toggle() }
    }
}

/// Names the selected detection or region and offers the next step.
struct SelectionCard: View {
    let store: FireStore

    var body: some View {
        if let d = store.selected {
            card(title: "\(d.sensor.rawValue) detection",
                 subtitle: "\(store.regionName(of: d)). \(megawatts(d.frp)), \(coordinateText(d.latitude, d.longitude)).",
                 badge: verdict(d),
                 primary: ("Open on map", { store.mode = .map; store.focus(on: d) }),
                 secondary: store.selectionStack.count > 1
                    ? ("Next of \(store.selectionStack.count)", { store.stepSelection(1) })
                    : ("Clear", { store.clearSelection() }))
        } else if let r = store.selectedRegion {
            card(title: r.name,
                 subtitle: "\(r.continent). \(r.count.grouped) detections in view.",
                 badge: (r.activity.rawValue, r.activity.color, r.activity.symbol),
                 primary: ("Open on map", { store.mode = .map }),
                 secondary: ("Next region", { store.stepRegion(1) }))
        }
    }

    private func verdict(_ d: FireDetection) -> (String, Color, String)? {
        guard store.wildfireProbability(d) != nil else { return nil }
        return store.isWildfire(d) ? ("Wildfire", Theme.poor, "flame.fill") : ("Not wildfire", Theme.chip, "minus")
    }

    private func card(title: String, subtitle: String, badge: (String, Color, String)?,
                      primary: (String, () -> Void), secondary: (String, () -> Void)) -> some View {
        Card(padding: 16, radius: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.serif(32)).lineLimit(1).minimumScaleFactor(0.6)
                        Text(subtitle).font(.body(12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let badge { StatusBadge(text: badge.0, color: badge.1, symbol: badge.2) }
                }
                HStack(spacing: 10) {
                    ActionButton(title: primary.0, action: primary.1)
                    ActionButton(title: secondary.0, primary: false, action: secondary.1)
                }
            }
        }
        .frame(width: 400)
    }
}

/// Download progress, errors and empty results, shown above the bottom row of the globe and the map.
struct StatusNotices: View {
    let store: FireStore

    var body: some View {
        Group {
            if let e = store.error {
                NoticeCard(symbol: "exclamationmark", color: e == .offline ? Theme.fair : Theme.poor,
                           title: e.title, message: e.recoverySuggestion,
                           action: retryable(e) ? ("Try again", { store.refresh() }) : nil,
                           onDismiss: { store.error = nil })
            } else if store.emptyResultNotice {
                NoticeCard(symbol: "checkmark", color: Theme.good, title: "No fires detected",
                           message: "FIRMS returned no MODIS and no VIIRS detections for this area and these dates. Try a wider area, more days, or a different VIIRS satellite.",
                           onDismiss: { store.dismissEmptyNotice() })
            } else if store.isLoading {
                Card(padding: 12, radius: 18) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.loadingStatus.isEmpty ? "Working…" : store.loadingStatus).font(.body(13, .semibold))
                        LinkButton(title: "Cancel") { store.cancelRefresh() }
                            .keyboardShortcut(".", modifiers: .command)
                    }
                }
                .fixedSize()
            } else if store.detections.isEmpty, store.lastUpdated == nil {
                NoticeCard(symbol: "flame.fill", color: Theme.fair, title: "No fire data yet",
                           message: store.hasMapKey ? "Download the latest detections from NASA FIRMS to fill the globe."
                                                    : "Add your free NASA FIRMS key to MyApp/Secrets.plist, then build again. See README.md.",
                           action: store.hasMapKey ? ("Download", { store.refresh() }) : nil)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(duration: 0.35), value: store.error)
        .animation(.spring(duration: 0.35), value: store.isLoading)
        .animation(.spring(duration: 0.35), value: store.emptyResultNotice)
    }

    private func retryable(_ e: FIRMSError) -> Bool {
        switch e {
        case .missingKey, .invalidKey, .invalidArea: false
        default: true
        }
    }
}

/// A short bar running from an ember colour's faint end to its strong end.
private struct FireSwatch: View {
    let colors: [Color]
    var body: some View {
        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)).frame(width: 34, height: 6)
    }
}
