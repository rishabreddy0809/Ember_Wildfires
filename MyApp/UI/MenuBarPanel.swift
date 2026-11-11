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
            HStack {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("Ember").font(.system(size: 14, weight: .bold))
                Spacer()
                Text((store.loadedQuery ?? store.query).areaName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                ForEach(Sensor.allCases) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            SensorGlyph(sensor: s, size: 8)
                            Text(s.rawValue).font(.wide(10)).tracking(1)
                        }
                        Text(store.count(s).grouped).font(.hudNumber(20)).foregroundStyle(Theme.color(s))
                            .contentTransition(.numericText())
                        Text(s.nominalResolution).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.color(s).opacity(0.12), in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.color(s).opacity(0.3)))
                }
            }
            Group {
                if store.isLoading {
                    Label(store.loadingStatus, systemImage: "antenna.radiowaves.left.and.right")
                } else if let e = store.error {
                    Label(e.title, systemImage: e.symbol).foregroundStyle(Theme.danger)
                } else if let u = store.lastUpdated {
                    Label("Updated \(u.formatted(.relative(presentation: .named)))\(store.isShowingCachedData ? " (cached)" : "")", systemImage: "clock")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecondary)

            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                    .disabled(store.isLoading)
                Spacer()
                Button("Open Ember") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .preferredColorScheme(.dark)
        .task { await store.start() }
    }
}
