//  MenuBarPanel.swift
//  The menu bar item: a flame with the live detection count. Clicking it opens a small
//  panel with each sensor's count, the last update time, and Refresh / Open Ember buttons.

import SwiftUI

struct MenuBarLabel: View {
    let store: FireStore
    var body: some View {
        let total = store.detections.count
        Image(systemName: store.isLoading ? "flame" : "flame.fill")
        if total > 0 { Text(total.grouped) }
    }
}

struct MenuBarPanel: View {
    let store: FireStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ember").font(.serif(24))
                Spacer()
                Text((store.loadedQuery ?? store.query).areaName).font(.body(12.5)).foregroundStyle(Theme.ink2)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Sensor.allCases) { s in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            SensorGlyph(sensor: s, size: 10)
                            Text(s.rawValue).font(.body(13, .semibold))
                        }
                        Text(store.count(s).grouped).font(.serif(32)).monospacedDigit().contentTransition(.numericText())
                        Text(s.nominalResolution + " pixels").font(.body(12)).foregroundStyle(Theme.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divide()
            Group {
                if store.isLoading {
                    Text(store.loadingStatus)
                } else if let e = store.error {
                    Text(e.title).foregroundStyle(Theme.poor)
                } else if let u = store.lastUpdated {
                    Text("Updated \(u.formatted(.relative(presentation: .named)))\(store.isShowingCachedData ? " (saved copy)" : "")")
                } else {
                    Text("No data yet")
                }
            }
            .font(.body(12.5))
            .foregroundStyle(Theme.ink2)

            HStack(spacing: 10) {
                ActionButton(title: "Refresh", primary: false) { store.refresh() }
                    .disabled(store.isLoading)
                ActionButton(title: "Open Ember") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .foregroundStyle(Theme.ink)
        .background(LinearGradient(colors: [Theme.cream0, Theme.cream1], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.light)
        .task { await store.start() }
    }
}
