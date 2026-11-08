//  MapHUD.swift
//  The glass panels that float over the map: legend, cursor readout, loading pill, and banners.

import SwiftUI
import CoreLocation

/// Top-left legend: what each marker shape means and how marker size relates to FRP.
struct LegendHUD: View {
    let store: FireStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Sensor.allCases) { s in
                Button { withAnimation(.snappy) { store.toggle(s) } } label: {
                    HStack(spacing: 8) {
                        SensorGlyph(sensor: s, size: 10, glow: store.visibleSensors.contains(s))
                        Text(s.rawValue).font(.system(size: 10.5, weight: .heavy).width(.expanded)).tracking(1)
                        Text(s.nominalResolution).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(store.count(s).grouped).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    .opacity(store.visibleSensors.contains(s) ? 1 : 0.4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 6) {
                ForEach([1.0, 10, 100, 1000], id: \.self) { frp in
                    let r = SensorPalette.radius(frp: frp)
                    Circle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                        .frame(width: r * 2, height: r * 2)
                }
                Text("size = FRP (log)").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .frame(height: 22)
        }
        .padding(12)
        .frame(width: 210)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// Bottom-left readout: cursor position, the area, and the date range of the data on screen.
struct ReadoutHUD: View {
    let store: FireStore
    let cursor: CLLocationCoordinate2D?
    var body: some View {
        let q = store.loadedQuery ?? store.query
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HUDLabel("Cursor")
                Text(cursor.map { String(format: "%@ %@", lat($0.latitude), lon($0.longitude)) } ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 170, alignment: .leading)
            }
            Divider().frame(height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HUDLabel(q.areaName)
                Text("\(FireQuery.firmsDateString(q.startDate)) → \(FireQuery.firmsDateString(q.endDate)) UTC")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            Divider().frame(height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HUDLabel("Showing")
                Text("\(store.displayedDetections.count.grouped) pts")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func lat(_ v: Double) -> String { String(format: "%07.4f°%@", abs(v), v >= 0 ? "N" : "S") }
    private func lon(_ v: Double) -> String { String(format: "%08.4f°%@", abs(v), v >= 0 ? "E" : "W") }
}

/// Top-center pill shown while downloading.
struct LoadingPill: View {
    let status: String
    let onCancel: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(status).font(.system(size: 11.5, weight: .semibold))
            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut(".", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular.tint(Theme.viirs.opacity(0.15)), in: .capsule)
    }
}

/// Bottom-center banner for errors and empty results.
struct BannerView: View {
    let symbol: String
    let title: String
    let message: String?
    let tint: Color
    var primary: (label: String, action: () -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .bold))
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if let primary {
                Button(primary.label, action: primary.action).buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
            }
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 560)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 16))
    }
}
