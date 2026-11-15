//  RootView.swift
//  The main window: a dark sky with three cream columns on it. The sidebar is on the
//  left, the globe, map or model view is in the middle, and the details are on the right.
//  The strip along the top holds the wordmark, the three views as pill tabs, and the
//  controls you use most. Most of them also have keyboard shortcuts (see AppCommands.swift).

import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var store: FireStore
    @State private var exportError: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.sky0, Theme.sky1], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                TopStrip(store: store)
                HStack(spacing: 12) {
                    SidebarView(store: store).frame(width: 320)
                    ZStack {
                        // The globe stays alive behind the other views (it pauses itself),
                        // so coming back to it is instant.
                        GlobeTab(store: store)
                            .opacity(store.mode == .globe ? 1 : 0)
                            .allowsHitTesting(store.mode == .globe)
                            .accessibilityHidden(store.mode != .globe)
                        if store.mode == .map { MapTab(store: store).transition(.opacity) }
                        if store.mode == .model { ModelTab(store: store).transition(.opacity) }
                    }
                    .animation(.easeInOut(duration: 0.25), value: store.mode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.showInspector {
                        InspectorView(store: store).frame(width: 356)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding([.horizontal, .bottom], 12)
            }
        }
        .animation(.smooth(duration: 0.3), value: store.showInspector)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .tint(Theme.teal)
        .task { await store.start() }
        .onExitCommand { store.clearSelection() }   // Esc clears the selection
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
}

/// Window strip: wordmark, the three views as pill tabs, what data is loaded, and the main controls.
struct TopStrip: View {
    let store: FireStore

    var body: some View {
        let q = store.loadedQuery ?? store.query
        ZStack {
            HStack(spacing: 8) {
                ForEach(AppMode.allCases) { m in
                    PillTab(m.rawValue, selected: store.mode == m, onDark: true, compact: true) { store.mode = m }
                }
            }
            HStack(spacing: 9) {
                Spacer().frame(width: 70)   // room for the window's close, minimise and zoom buttons
                FlameMark()
                Text("Ember").font(.serif(23)).foregroundStyle(Theme.onDark)
                Spacer()
                HStack(spacing: 7) {
                    if store.isLoading {
                        ProgressView().controlSize(.mini).tint(Theme.onDark).colorScheme(.dark)
                    } else {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                    }
                    Text(store.isLoading ? "Updating…" : "\(q.areaName) · \(dateRangeText(q))")
                        .font(.body(13, .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                }
                .padding(.horizontal, 13).frame(height: 30)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .help(statusHelp)
                .accessibilityElement(children: .combine)
                RoundIcon(symbol: "arrow.clockwise") { store.refresh() }
                    .disabled(store.isLoading)
                    .help("Download the latest detections  ⌘R")
                    .accessibilityLabel("Refresh")
                RoundIcon(symbol: "square.and.arrow.up") { store.beginExport() }
                    .disabled(store.rawDetections.isEmpty)
                    .help("Export every detection as CSV  ⌘E")
                    .accessibilityLabel("Export CSV")
                Spacer().frame(width: 6)
                RoundIcon(symbol: "sidebar.right", active: store.showInspector) { store.showInspector.toggle() }
                    .help("Details  ⌥⌘I")
                    .accessibilityLabel("Details")
            }
            .padding(.trailing, 14)
        }
        .frame(height: 50)
    }

    private var statusColor: Color {
        if store.error != nil { return Theme.poor }
        if store.isShowingCachedData { return Theme.fair }
        return store.lastUpdated == nil ? Theme.ink3 : Theme.good
    }

    private var statusHelp: String {
        guard let updated = store.lastUpdated else { return "Nothing downloaded yet" }
        let when = updated.formatted(date: .abbreviated, time: .shortened)
        return store.isShowingCachedData ? "Saved copy, downloaded \(when)" : "Downloaded \(when)"
    }
}
