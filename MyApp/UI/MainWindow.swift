//  MainWindow.swift
//  The main window: sidebar on the left, a full-bleed map, and an inspector on the right.
//  The toolbar holds the controls you use most. Most of them also have keyboard shortcuts (see AppCommands.swift).

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
            mapArea
        }
        .inspector(isPresented: $store.showInspector) {
            InspectorView(store: store)
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
        ZStack {
            DetectionMapView(store: store) { cursor = $0 }
                .ignoresSafeArea()

            // A soft shadow around the edges so the floating panels stay readable on bright imagery
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 300, endRadius: 1100)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    LegendHUD(store: store)
                    Spacer()
                }
                Spacer()
                HStack(alignment: .bottom) {
                    ReadoutHUD(store: store, cursor: cursor)
                    Spacer()
                }
            }
            .padding(16)

            VStack {
                if store.isLoading {
                    LoadingPill(status: store.loadingStatus) { store.cancelRefresh() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if store.isShowingCachedData, store.lastUpdated != nil {
                    cachedPill.transition(.opacity)
                }
                Spacer()
                banner
                    .padding(.bottom, 76)
            }
            .padding(.top, 14)
            .padding(.horizontal, 16)
            .animation(.spring(duration: 0.35), value: store.isLoading)
            .animation(.spring(duration: 0.35), value: store.error)
        }
        .onExitCommand { store.clearSelection() }   // Esc clears the selection
    }

    private var cachedPill: some View {
        Label {
            Text("Offline copy · \(store.lastUpdated!.formatted(.relative(presentation: .named)))")
        } icon: {
            Image(systemName: "externaldrive.fill.badge.timemachine")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(.regular.tint(Theme.modis.opacity(0.15)), in: .capsule)
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
        ToolbarItemGroup(placement: .principal) {
            ForEach(Sensor.allCases) { s in
                Toggle(isOn: Binding(get: { store.visibleSensors.contains(s) }, set: { _ in withAnimation(.snappy) { store.toggle(s) } })) {
                    Label { Text(s.rawValue) } icon: { SensorGlyph(sensor: s, size: 9, glow: false) }
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .help("Show/hide \(s.rawValue) (\(s == .modis ? "⌘1" : "⌘2"))")
            }
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
}
