//  AppCommands.swift
//  Menu bar menus and keyboard shortcuts.
//
//  ⌘R  Refresh               ⌘.   Cancel download
//  ⌘E  Export CSV…           ⌘↩   Fetch with the current sidebar settings
//  ⌘1  Toggle MODIS          ⌘2   Toggle VIIRS
//  ⌘0  Zoom to area          ⌥⌘I  Show/hide inspector
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
            Divider()
            Menu("Area") {
                ForEach(AreaPreset.all) { p in Button(p.name) { store.selectPreset(p) } }
                Divider()
                Button("Use Visible Map Area") { store.useVisibleMapArea() }
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom to Area") { store.zoomToArea() }
                .keyboardShortcut("0")
            Button(store.showInspector ? "Hide Inspector" : "Show Inspector") { store.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Picker("Map Style", selection: Binding(get: { store.mapStyle }, set: { store.mapStyle = $0 })) {
                ForEach(MapStyleChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
        }
    }
}
