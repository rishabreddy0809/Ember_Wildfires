import Foundation
let root = CommandLine.arguments[1] + "/MyApp/ML/"
let forest = try! EmberForest(data: Data(contentsOf: URL(fileURLWithPath: root + "ember_rf.bin")))
let grids = try! StaticGrids(data: Data(contentsOf: URL(fileURLWithPath: root + "ember_static.bin")))
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail)); if !ok { failures += 1 } }
let t0 = Date(timeIntervalSince1970: 1_629_000_000) // 2021-08-15
func det(_ lat: Double, _ lon: Double, sensor: Sensor = .viirs, frp: Double? = 5, at: Date? = t0, conf: DetectionConfidence = .category(.nominal),
         b1: Double? = 330, b2: Double? = 290, scan: Double? = 0.4, track: Double? = 0.4, dn: DayNight = .day) -> FireDetection {
  FireDetection(id: UUID(), sensor: sensor, source: "", latitude: lat, longitude: lon, brightness: b1, brightness2: b2, scan: scan, track: track,
    acqDate: "2021-08-15", acqTime: "2000", acquiredAt: at, satellite: "N", instrument: nil, confidence: conf, version: "", frp: frp, dayNight: dn, type: nil, allColumns: [])
}
func valid(_ s: [UUID: Float]) -> Bool { s.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }
func run(_ d: [FireDetection]) -> [UUID: Float] { WildfireClassifier.scores(for: d, forest: forest, grids: grids) }

check("empty input", run([]).isEmpty)
let one = det(39.8, -121.4); let s1 = run([one]); check("single detection", s1.count == 1 && valid(s1), "p=\(s1.values.first ?? -1)")
let allNil = det(39.8, -121.4, sensor: .modis, frp: nil, conf: .unknown("?"), b1: nil, b2: nil, scan: nil, track: nil, dn: .unknown)
check("every optional field missing", valid(run([allNil])) && run([allNil]).count == 1)
check("no acquisition time is skipped, not crashed", run([det(39.8, -121.4, at: nil), one]).count == 1)
check("impossible coordinates skipped", run([det(.nan, -121.4), det(95, 0), det(0, 200), one]).count == 1)
let edges = [det(89.999, 0), det(-90, 179.99), det(0, 180), det(0, -180), det(90, -180), det(-89.5, 179.9, sensor: .modis)]
let se = run(edges); check("poles and the dateline", se.count == edges.count && valid(se))
let outside = run([det(-33.9, 151.2), det(64.8, -147.7)]); check("outside the static grid (Sydney, Fairbanks)", outside.count == 2 && valid(outside))
check("zero-area pixel (scan 0)", valid(run([det(39.8, -121.4, scan: 0, track: 0)])))
check("huge / negative values", valid(run([det(39.8, -121.4, frp: 1e9, b1: 1e6, b2: -50), det(39.8, -121.4, frp: -3), det(39.8, -121.4, frp: .infinity)])))
check("dates far in the past and future", valid(run([det(39.8, -121.4, at: Date(timeIntervalSince1970: 0)), det(39.8, -121.4, at: Date(timeIntervalSince1970: 4e9))])))
let dupes = (0..<500).map { _ in det(39.8, -121.4) }; let sd = run(dupes)
check("500 identical detections", sd.count == 500 && Set(sd.values).count == 1)
// Determinism: same input in a different order gives the same scores
var rng = SystemRandomNumberGenerator()
var mixed: [FireDetection] = []
for i in 0..<3000 {
  let lat: Double = 38 + Double.random(in: 0...3, using: &rng)
  let lon: Double = -122 + Double.random(in: 0...3, using: &rng)
  let frp: Double = Double.random(in: 0...200, using: &rng)
  let at: Date = t0.addingTimeInterval(Double.random(in: -172800...172800, using: &rng))
  let sensor: Sensor = i % 3 == 0 ? .modis : .viirs
  let dn: DayNight = i % 2 == 0 ? .day : .night
  mixed.append(det(lat, lon, sensor: sensor, frp: frp, at: at, dn: dn))
}
let a = run(mixed), b = run(mixed.shuffled())
check("order doesn't change scores", mixed.allSatisfy { a[$0.id] == b[$0.id] })
// One satellite missing: model should still flag a big fire cluster
var cluster: [FireDetection] = []
for i in 0..<60 {
  let lat: Double = 39.8 + Double(i % 8) * 0.004
  let lon: Double = -121.4 + Double(i / 8) * 0.004
  let dn: DayNight = i % 2 == 0 ? .day : .night
  cluster.append(det(lat, lon, sensor: .viirs, frp: 40, dn: dn))
}
let sc = run(cluster); let meanP = sc.values.reduce(0, +) / Float(sc.count)
check("VIIRS-only forest fire cluster still looks like wildfire", meanP >= WildfireClassifier.threshold, "mean p=\(meanP)")
// Scale: a big download
for n in [20_000, 100_000, 200_000] {
  var big: [FireDetection] = []
  for i in 0..<n {
    let lat: Double = 32.5 + Double.random(in: 0...9.5, using: &rng)
    let lon: Double = -124.4 + Double.random(in: 0...10, using: &rng)
    let sensor: Sensor = i % 4 == 0 ? .modis : .viirs
    big.append(det(lat, lon, sensor: sensor, frp: Double.random(in: 0...500, using: &rng), at: t0.addingTimeInterval(Double(i % 10) * 86400)))
  }
  let start = Date(); let s = run(big); let dt = Date().timeIntervalSince(start)
  check("\(n) detections over 10 days", s.count == n && valid(s), String(format: "%.2fs", dt))
}
// Dense fire: 30k detections inside 20 km over 2 days (worst case for neighbour search)
var dense: [FireDetection] = []
for i in 0..<30_000 {
  let lat: Double = 39.8 + Double.random(in: 0...0.18, using: &rng)
  let lon: Double = -121.4 + Double.random(in: 0...0.23, using: &rng)
  let sensor: Sensor = i % 5 == 0 ? .modis : .viirs
  dense.append(det(lat, lon, sensor: sensor, at: t0.addingTimeInterval(Double(i % 2) * 86400)))
}
let ds = Date(); let sdn = run(dense); check("30,000 detections packed in one 20 km fire", sdn.count == dense.count && valid(sdn), String(format: "%.2fs", Date().timeIntervalSince(ds)))
// Corrupt model files must fail cleanly, not crash
check("corrupt forest file rejected", (try? EmberForest(data: Data("EMRFgarbage".utf8))) == nil)
check("truncated forest file rejected", (try? EmberForest(data: try! Data(contentsOf: URL(fileURLWithPath: root + "ember_rf.bin")).prefix(5000))) == nil)
check("corrupt grid file rejected", (try? StaticGrids(data: Data(repeating: 7, count: 100))) == nil)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
