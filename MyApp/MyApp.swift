//  MyApp.swift
//  App entry point. It creates the shared FireStore and the three scenes:
//  the main window, the menu bar item, and the Settings window.

import SwiftUI

@main
struct EmberApp: App {
    /// One store for the whole app, so the window, the menu bar item, and the menus all show the same data.
    @State private var store = FireStore()

    init() { Theme.registerFonts() }

    var body: some Scene {
        Window("Ember", id: "main") {
            RootView(store: store)
                .frame(minWidth: 1240, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1520, height: 940)
        .commands { AppCommands(store: store) }

        MenuBarExtra {
            MenuBarPanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
