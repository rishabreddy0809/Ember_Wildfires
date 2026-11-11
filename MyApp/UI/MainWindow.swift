//  MainWindow.swift
//  The main window: sidebar on the left, a full-bleed map, and an inspector column on the right.
//  Glass panels float over the map: the legend (top right) and the overpass timeline (bottom).
//  The toolbar shows what data is on screen and holds the controls you use most.
//  Most of them also have keyboard shortcuts (see AppCommands.swift).

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct MainWindow: View {
    @Bindable var store: FireStore
    @State private var cursor: CLLocationCoordinate2D?
    @State private var exportError: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            // The inspector is a plain column beside the map instead of SwiftUI's `.inspector`.
            // On macOS 27, `.inspector` made the window's content twice as tall as the window
            // when it opened, which pushed the legend, timeline, and status footer off screen.
            HStack(spacing: 0) {
                mapArea
                if store.showInspector {
                    InspectorView(store: store)
                        .frame(width: 340)
                        .background(Theme.background.ignoresSafeArea())
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea()
                        }
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.28), value: store.showInspector)
        }
        .toolbar { toolbar }
        .navigationTitle("")
        .preferredColorScheme(.dark)
        .tint(Theme.ember)
        .task { await store.start() }
        .fileExporter(isPresented: $store.isExporting,
                      document: store.exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: store.exportFilename) { result in
            if case .failure(let e) = result { exportError = e.localizedDescription }
        }
        .alert("Export failed", isPresented: .constant(exportError != nil), presenting: exportError) { _ in
            Button("OK") { exportError = nil }
        } message: { Text($0) }
    }

    // MARK: Map + floating overlays

    private var mapArea: some View {
        DetectionMapView(store: store) { cursor = $0 }
            .ignoresSafeArea()
            .overlay {
                // A soft shadow around the edges so the floating panels stay readable on bright imagery
                RadialGradient(colors: [.clear, .black.opacity(0.4)], center: .center, startRadius: 320, endRadius: 1100)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                // Top right, because the map draws its distance scale in the top-left corner.
                LegendHUD(store: store).padding(16)
            }
            .overlay(alignment: .top) {
                Group {
                    if store.isLoading {
                        LoadingPill(status: store.loadingStatus) { store.cancelRefresh() }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if store.isShowingCachedData, let updated = store.lastUpdated {
                        CachedPill(updated: updated).transition(.opacity)
                    }
                }
                .padding(.top, 16)
                .animation(.spring(duration: 0.35), value: store.isLoading)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    banner
                    TimelineDock(store: store, cursor: cursor)
                }
                // Leave room on the right for the map's zoom buttons.
                .padding(.leading, 16).padding(.trailing, 64).padding(.bottom, 16)
                .animation(.spring(duration: 0.35), value: store.error)
                .animation(.spring(duration: 0.35), value: store.emptyResultNotice)
            }
            .onExitCommand { store.clearSelection() }   // Esc clears the selection
    }

    @ViewBuilder private var banner: some View {
        if let e = store.error {
            BannerView(symbol: e.symbol, title: e.title, message: e.recoverySuggestion,
                       tint: e == .offline ? Theme.modis : Theme.danger,
                       primary: retryAction(for: e),
                       onDismiss: { store.error = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if store.emptyResultNotice {
            BannerView(symbol: "checkmark.seal", title: "No fires detected",
                       message: "FIRMS returned 0 MODIS and 0 VIIRS detections for this area and date range. Try a wider area, more days, or a different VIIRS satellite.",
                       tint: Theme.viirs, primary: nil, onDismiss: { store.dismissEmptyNotice() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func retryAction(for e: FIRMSError) -> (label: String, action: () -> Void)? {
        switch e {
        case .missingKey, .invalidKey, .invalidArea: nil
        default: ("Retry", { store.refresh() })
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The area and dates of the data on the map, where a window title would normally go.
        ToolbarItem(placement: .principal) {
            let q = store.loadedQuery ?? store.query
            HStack(spacing: 8) {
                Text(q.areaName).font(.system(size: 13, weight: .semibold))
                Text(dateRange(q))
                    .font(.mono(11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("Map Style", selection: $store.mapStyle) {
                ForEach(MapStyleChoice.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Base map style")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: store.isLoading)
            }
            .disabled(store.isLoading)
            .help("Download the latest detections (⌘R)")

            Button { store.beginExport() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .disabled(store.rawDetections.isEmpty)
                .help("Export combined MODIS + VIIRS detections as CSV (⌘E)")

            Button { store.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show/hide the detection inspector (⌥⌘I)")
        }
    }

    /// "2026-11-07 → 2026-11-08 UTC", or a single date when the range is one day.
    private func dateRange(_ q: FireQuery) -> String {
        let start = FireQuery.firmsDateString(q.startDate), end = FireQuery.firmsDateString(q.endDate)
        return (start == end ? start : "\(start) → \(end)") + " UTC"
    }
}
