import Foundation
let root = CommandLine.arguments[1]
let forest = try! EmberForest(data: Data(contentsOf: URL(fileURLWithPath: root + "/MyApp/ML/ember_rf.bin")))
let grids = try! StaticGrids(data: Data(contentsOf: URL(fileURLWithPath: root + "/MyApp/ML/ember_static.bin")))
let thr = Float(try! String(contentsOfFile: root + "/ml/outputs/swift_threshold.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
print("threshold python \(thr) swift \(WildfireClassifier.threshold) \(thr == WildfireClassifier.threshold ? "OK" : "MISMATCH")")
let text = try! String(contentsOfFile: root + "/ml/outputs/swift_golden.csv", encoding: .utf8)
var lines = text.split(separator: "\n").map(String.init); let header = lines.removeFirst().split(separator: ",").map(String.init)
func col(_ n: String) -> Int { header.firstIndex(of: n)! }
let fmt = DateFormatter(); fmt.timeZone = TimeZone(identifier: "UTC"); fmt.dateFormat = "yyyy-MM-dd HHmm"
let names = WildfireClassifier.featureNames
let checked = names.enumerated().filter { header.contains($0.element) }   // context + static columns
var dets: [FireDetection] = []; var expected: [(feats: [Double], prob: Double)] = []
for l in lines {
  let c = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
  let sensor: Sensor = c[col("sensor")] == "MODIS" ? .modis : .viirs
  let cls = Int(Double(c[col("conf_class")]) ?? -1)
  let conf: DetectionConfidence = sensor == .modis ? (cls < 0 ? .unknown("") : .percent([10,50,90][cls])) : (cls < 0 ? .unknown("") : .category([.low,.nominal,.high][cls]))
  let t = c[col("time")]; let parts = t.split(separator: " ")
  dets.append(FireDetection(id: UUID(), sensor: sensor, source: "", latitude: Double(c[col("lat")])!, longitude: Double(c[col("lon")])!,
    brightness: Double(c[col("bright_mir")]), brightness2: Double(c[col("bright_tir")]), scan: Double(c[col("scan")]), track: Double(c[col("track")]),
    acqDate: String(parts[0]), acqTime: String(parts[1]), acquiredAt: fmt.date(from: t), satellite: "", instrument: nil, confidence: conf,
    version: "", frp: Double(c[col("frp")]), dayNight: c[col("is_day")] == "1" ? .day : .night, type: nil, allColumns: []))
  expected.append((checked.map { Double(c[col($0.element)]) ?? -1 }, Double(c[col("prob")])!))
}
let start = Date()
let x = HarmonizedFeatures.matrix(for: dets, grids: grids)
let scores = WildfireClassifier.scores(for: dets, forest: forest, grids: grids)
print("rows \(dets.count), \(checked.count) context/static features checked, features+inference \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
let n = names.count
var mismatch = 0, maxProbDiff = 0.0, flips = 0
for (i, d) in dets.enumerated() {
  for (k, (j, name)) in checked.enumerated() {
    let e = expected[i].feats[k], s = Double(x[i*n + j])
    if abs(s - e) > 1e-3 * max(1, abs(e)) { mismatch += 1; if mismatch <= 8 { print("row \(i) \(name) swift \(s) python \(e)") } }
  }
  let p = Double(scores[d.id]!); maxProbDiff = max(maxProbDiff, abs(p - expected[i].prob))
  if (p >= Double(thr)) != (expected[i].prob >= Double(thr)) { flips += 1 }
}
print("feature mismatches: \(mismatch), max |prob diff|: \(maxProbDiff), decisions that differ: \(flips)")
