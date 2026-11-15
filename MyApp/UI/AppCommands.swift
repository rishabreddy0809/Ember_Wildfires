//  AppCommands.swift
//  Menu bar menus and keyboard shortcuts.
//
//  ⌘R  Refresh               ⌘.   Cancel download
//  ⌘E  Export CSV…           ⌘↩   Fetch with the current sidebar settings
//  ⌘1  Toggle MODIS          ⌘2   Toggle VIIRS
//  ⌘3  Harmonized ML filter (wildfires only)
//  ⌘0  Zoom to area          ⌥⌘I  Show/hide details
//  ⌥⌘1 Globe   ⌥⌘2 Map   ⌥⌘3 Model      ⌘↓ ⌘↑  Next / previous region
//  [ ] Step through overlapping detections     Esc  Clear selection

import SwiftUI

struct AppCommands: Commands {
    let store: FireStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}   // This is a single-window app, so there is no "New Window"

        CommandGroup(replacing: .importExport) {
            Button("Export Detections as CSV…") { store.beginExport() }
                .keyboardShortcut("e")
                .disabled(store.rawDetections.isEmpty)
        }

        CommandMenu("Data") {
            Button("Refresh") { store.refresh() }
                .keyboardShortcut("r")
                .disabled(store.isLoading)
            Button("Cancel Download") { store.cancelRefresh() }
                .disabled(!store.isLoading)
            Divider()
            Toggle("Show MODIS", isOn: Binding(get: { store.visibleSensors.contains(.modis) }, set: { _ in store.toggle(.modis) }))
                .keyboardShortcut("1")
            Toggle("Show VIIRS", isOn: Binding(get: { store.visibleSensors.contains(.viirs) }, set: { _ in store.toggle(.viirs) }))
                .keyboardShortcut("2")
            Toggle("Harmonized ML: Wildfires Only", isOn: Binding(get: { store.mlFilter },
                                                                  set: { store.displayMode = $0 ? .wildfireML : .both }))
                .keyboardShortcut("3")
                .disabled(!WildfireClassifier.isAvailable)
            Divider()
            Button("Next Region") { store.stepRegion(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Region") { store.stepRegion(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Menu("Area") {
                ForEach(AreaPreset.all) { p in Button(p.name) { store.selectPreset(p) } }
                Divider()
                Button("Use Visible Map Area") { store.useVisibleMapArea() }
            }
        }

        CommandGroup(after: .sidebar) {
            ForEach(Array(AppMode.allCases.enumerated()), id: \.element) { i, m in
                Button(m.rawValue) { store.mode = m }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Zoom to Area") { store.zoomToArea() }
                .keyboardShortcut("0")
            Button(store.showInspector ? "Hide Details" : "Show Details") { store.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Picker("Map Style", selection: Binding(get: { store.mapStyle }, set: { store.mapStyle = $0 })) {
                ForEach(MapStyleChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
        }
    }
}
