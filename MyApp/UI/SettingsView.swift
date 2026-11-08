//  SettingsView.swift
//  Ember ▸ Settings… (⌘,): MAP_KEY status, refresh behavior, and cache management.

import SwiftUI
import AppKit

struct SettingsView: View {
    let store: FireStore
    @AppStorage("refreshOnLaunch") private var refreshOnLaunch = true
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section("NASA FIRMS MAP_KEY") {
                if let key = SecretsLoader.mapKey() {
                    LabeledContent("Status") {
                        Label("Loaded from Secrets.plist", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    LabeledContent("Key") { Text(SecretsLoader.masked(key)).font(.mono) }
                } else {
                    LabeledContent("Status") {
                        Label("Not configured", systemImage: "key.slash").foregroundStyle(Theme.danger)
                    }
                    Text("1. Get a free key at firms.modaps.eosdis.nasa.gov/api/map_key\n2. Paste it into MyApp/Secrets.plist (FIRMS_MAP_KEY)\n3. Rebuild and run (⌘R in Xcode)")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Request a MAP_KEY", destination: URL(string: "https://firms.modaps.eosdis.nasa.gov/api/map_key/")!)
                }
            }

            Section("Refreshing") {
                Toggle("Refresh automatically when Ember opens", isOn: $refreshOnLaunch)
                LabeledContent("Transactions used (10 min)") {
                    Text("\(store.transactionsUsed) / \(RateLimiter.budgetPerWindow)").font(.mono)
                }
                Text("FIRMS allows 5,000 transactions per key in each 10-minute window. Ember sets itself a much lower limit and waits \(Int(RateLimiter.cooldown)) s between refreshes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Offline cache") {
                LabeledContent("Location") {
                    Text(DetectionCache.fileURL.path(percentEncoded: false))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DetectionCache.fileURL])
                    }
                    Button("Clear Cache", role: .destructive) { store.clearCache(); cacheCleared = true }
                    if cacheCleared { Text("Cleared").foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }
}
