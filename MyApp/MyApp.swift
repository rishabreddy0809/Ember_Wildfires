//  MyApp.swift
//  App entry point. It creates the shared FireStore and the three scenes:
//  the main window, the menu bar item, and the Settings window.

import SwiftUI

@main
struct EmberApp: App {
    /// One store for the whole app, so the window, the menu bar item, and the menus all show the same data.
    @State private var store = FireStore()

    var body: some Scene {
        Window("Ember", id: "main") {
            MainWindow(store: store)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 920)
        .windowToolbarStyle(.unified)
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
