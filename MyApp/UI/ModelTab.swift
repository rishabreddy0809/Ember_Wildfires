//  ModelTab.swift
//  The Model view: what the wildfire classifier is, how well it tested, what it looks at,
//  and what it makes of the detections loaded right now.

import SwiftUI
import Charts

struct ModelTab: View {
    let store: FireStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Telling wildfires from everything else").font(.serif(38))
                        Text("A satellite flags any hot pixel: a wildfire, but also a farmer burning stubble, a gas flare, a steel plant, or a patch of sun-baked ground. Ember's model reads MODIS and VIIRS together and gives every detection a probability that it is a real wildfire.")
                            .font(.body(14)).foregroundStyle(Theme.ink2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        Divide()
                        HStack(alignment: .top, spacing: 16) {
                            BigStat(label: "Accuracy", value: "97%", caption: "Of 2021 California detections it had never seen.")
                            BigStat(label: "Precision", value: "99%", caption: "Of those it called wildfire, this share were.")
                            BigStat(label: "Noise removed", value: "92%", caption: "Of detections that were not wildfire.")
                            BigStat(label: "Fires caught", value: "126", caption: "Of 168 fires mapped by CAL FIRE that year.")
                        }
                        Text("Trained on every California detection of 2020, tested on 2021, at the default 60% cut. On 2022 and 2023 accuracy was 93% and 90%; calling everything a wildfire scores 45%.")
                            .font(.body(12.5)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("What it makes of today").font(.serif(28))
                            Text("Every loaded detection, by the probability the model gave it. Everything right of the line counts as wildfire.")
                                .font(.body(13)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                            DarkInset {
                                ScoreHistogram(counts: store.scoreHistogram, threshold: Double(store.mlThreshold))
                                    .frame(height: 190)
                                    .padding(14)
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Text("Filter sensitivity").font(.body(13, .semibold))
                                Spacer()
                                Text(String(format: "%.0f%%", store.mlThreshold * 100)).font(.body(13)).foregroundStyle(Theme.ink2)
                            }
                            PaperSlider(value: Binding(get: { Double(store.mlThreshold) }, set: { store.setThreshold(Float($0)) }),
                                        range: 0.3...0.8)
                                .accessibilityLabel("Filter sensitivity")
                            HStack(alignment: .top, spacing: 16) {
                                BigStat(label: "Kept", value: store.wildfireCount.grouped, caption: "Called wildfire at this setting.", size: 36)
                                BigStat(label: "Filtered out", value: max(0, store.detections.count - store.wildfireCount).grouped,
                                        caption: "Likely something else.", size: 36)
                            }
                            HStack(spacing: 10) {
                                ActionButton(title: store.mlFilter ? "Show every detection" : "Show wildfires only") {
                                    store.displayMode = store.mlFilter ? .both : .wildfireML
                                }
                                .disabled(!WildfireClassifier.isAvailable)
                                ActionButton(title: "Default setting", primary: false) { store.setThreshold(WildfireClassifier.threshold) }
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        Card {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("What it looks at").font(.serif(28)).padding(.bottom, 10)
                                Divide()
                                clue("Heat", "Brightness at two wavelengths, the gap between them, and fire power per square kilometre, put on one scale for both sensors.")
                                clue("Company", "How many other detections sit within 2 km and 5 km, and how strong they are. Wildfires come in clusters.")
                                clue("Agreement", "Whether the other sensor saw fire at the same spot that day or the day before.")
                                clue("Persistence", "Whether it burned through the night and the previous day. Farm burns rarely do.")
                                clue("Timing", "Hour and month, and whether it was day or night.")
                                clue("Ground", "Land cover and how often the spot burned in 2017 to 2019. California only.")
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 9) {
                                    StatusIcon(color: Theme.fair, symbol: "exclamationmark", size: 20)
                                    Text("Outside California").font(.body(14, .semibold))
                                }
                                Text("The model learned from California fires and CAL FIRE's mapped perimeters. It has not been tested anywhere else. Outside California it has no land-cover or burn-history data and works from heat, clustering and timing alone, so read its verdicts as a guide, not a measurement. The filter only changes what is shown: the saved download and the CSV export always keep every detection.")
                                    .font(.body(12.5)).foregroundStyle(Theme.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func clue(_ name: String, _ text: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(name).font(.body(13, .semibold)).frame(width: 84, alignment: .leading)
                Text(text).font(.body(12.5)).foregroundStyle(Theme.ink2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            Divide()
        }
    }
}

/// Detections by wildfire probability, in twenty bars, with the cut marked.
private struct ScoreHistogram: View {
    let counts: [Int]
    let threshold: Double

    var body: some View {
        if counts.allSatisfy({ $0 == 0 }) {
            Text(WildfireClassifier.isAvailable ? "No detections loaded yet" : "The model file is missing from the app.")
                .font(.body(12.5)).foregroundStyle(Theme.onDark.opacity(0.62))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(Array(counts.enumerated()), id: \.offset) { i, n in
                    let mid = (Double(i) + 0.5) / 20
                    RectangleMark(xStart: .value("From", Double(i) / 20 + 0.004), xEnd: .value("To", Double(i + 1) / 20 - 0.004),
                                  yStart: .value("Zero", 0), yEnd: .value("Detections", n))
                        .foregroundStyle(mid >= threshold ? Theme.modis : Color.white.opacity(0.28))
                        .cornerRadius(2)
                }
                RuleMark(x: .value("Cut", threshold))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(Theme.onDark)
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("cut").font(.body(10, .semibold)).foregroundStyle(Theme.onDark)
                    }
            }
            .chartXScale(domain: 0...1)
            .chartXAxis {
                AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { v in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.10))
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text("\(Int(d * 100))%") }
                    }
                    .font(.body(10)).foregroundStyle(Theme.onDark.opacity(0.62))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.10))
                    AxisValueLabel {
                        if let n = v.as(Int.self) { Text(n.grouped) }
                    }
                    .font(.body(10)).foregroundStyle(Theme.onDark.opacity(0.62))
                }
            }
            .animation(.snappy, value: threshold)
            .accessibilityLabel("Detections by wildfire probability")
        }
    }
}
