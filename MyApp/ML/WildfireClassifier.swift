//  WildfireClassifier.swift
//  Harmonized MODIS + VIIRS wildfire classifier (model v3).
//
//  A random forest trained in Python on every California detection of 2020 and tested on
//  2021 (ml/train_v3.py writes ember_rf.bin; ml/build_static_grids.py writes ember_static.bin).
//  Labels are CAL FIRE perimeters with one pixel of tolerance; small fires are weighted to
//  count as much as big ones.
//
//  For each detection it returns P(wildfire): the chance the pixel belongs to a real wildfire
//  rather than an agricultural or prescribed burn, an industrial heat source, or a false alarm.
//  Inputs:
//  • Radiometry on one scale for both sensors (brightness, ΔT, FRP per km², confidence class).
//  • Context from both sensors: clustering, cross-sensor confirmation, day/night persistence.
//    Only the same UTC day and the day before are used, never later data.
//  • Whether the other sensor reported anything that UTC day, so the model still works if
//    one satellite is offline (trained on single-sensor copies of the data).
//  • Static context: NLCD 2019 land cover and how often the spot burned in 2017–2019.
//  The features must stay identical to ml/train_v3.py (checked by a parity test, see ml/README.md).

import Foundation

nonisolated enum WildfireClassifier {
    /// Detections at or above this probability count as wildfire.
    /// Chosen by cross-validation on 2020 only (ml/outputs/swift_threshold.txt).
    static let threshold: Float = 0.6

    /// Feature order. Must match FEATURES in ml/train_v3.py.
    static let featureNames = [
        "is_viirs", "bright_mir", "bright_tir", "delta_t", "frp", "log_frp", "frp_density",
        "pixel_area_km2", "conf_class", "is_day", "hour_utc", "month",
        "n_same_2km_0d", "n_other_2km_prev1d", "maxfrp_other_2km_prev1d", "cross_sensor_confirmed",
        "n_all_5km_0d", "maxfrp_all_5km_0d", "sumfrp_all_5km_0d", "n_all_5km_prevday",
        "n_night_5km_prev1d", "n_day_5km_prev1d", "other_sensor_present",
        "lc_forest", "lc_shrub", "lc_grass", "lc_ag", "lc_dev", "hist_months",
    ]

    /// Measured on all 2021 California detections (model trained on 2020 only).
    static let testSummary = "2021 test at the default setting: 97% accuracy · 99% precision · removes 92% of non-wildfire detections · catches 126 of 168 mapped fires"

    private static let forest: EmberForest? = {
        guard let url = Bundle.main.url(forResource: "ember_rf", withExtension: "bin") else { return nil }
        return try? EmberForest(data: Data(contentsOf: url, options: .mappedIfSafe))
    }()

    private static let grids: StaticGrids? = {
        guard let url = Bundle.main.url(forResource: "ember_static", withExtension: "bin") else { return nil }
        return try? StaticGrids(data: Data(contentsOf: url))
    }()

    static var isAvailable: Bool { forest != nil }

    /// P(wildfire) for every detection that has a valid acquisition time.
    @concurrent
    static func scores(for detections: [FireDetection]) async -> [UUID: Float] {
        guard let forest, !detections.isEmpty else { return [:] }
        return scores(for: detections, forest: forest, grids: grids)
    }

    static func scores(for detections: [FireDetection], forest: EmberForest, grids: StaticGrids?) -> [UUID: Float] {
        // Skip anything the features can't be computed for (no time, impossible coordinates).
        let usable = detections.filter {
            $0.acquiredAt != nil && (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
        }
        let x = HarmonizedFeatures.matrix(for: usable, grids: grids)
        let n = featureNames.count
        // Each detection is scored on its own, so the work is spread over every core.
        var probabilities = [Float](repeating: 0, count: usable.count)
        x.withUnsafeBufferPointer { features in
            probabilities.withUnsafeMutableBufferPointer { result in
                Parallel.forEachChunk(of: usable.count) { range in
                    for i in range {
                        result[i] = forest.predict(UnsafeBufferPointer(rebasing: features[(i * n)..<((i + 1) * n)]))
                    }
                }
            }
        }
        var out: [UUID: Float] = [:]
        out.reserveCapacity(usable.count)
        for (i, d) in usable.enumerated() { out[d.id] = probabilities[i] }
        return out
    }
}

// MARK: - Parallel loops

/// Splits `count` items into chunks and runs `body` on each chunk at the same time, one
/// chunk per core. `body` must only write to places no other chunk touches.
nonisolated enum Parallel {
    static func forEachChunk(of count: Int, minimumChunk: Int = 2_000, _ body: (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 2, count / minimumChunk))
        guard chunks > 1 else { body(0..<count); return }
        let size = (count + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let start = c * size
            if start < count { body(start..<min(count, start + size)) }
        }
    }
}

// MARK: - Features

/// Turns detections from both sensors into one feature table (row-major, featureNames order).
/// Missing values are -1, as in training (`fillna(-1)`).
nonisolated enum HarmonizedFeatures {
    fileprivate static let earthKm = 6371.0

    fileprivate struct Point {
        let lat: Double, lon: Double
        let frp: Double            // nil FRP counts as 0, as in training
        let isVIIRS: Bool
        let isNight: Bool          // anything not flagged "D"
        let day: Int               // UTC day number
        let latR: Double, lonR: Double, cosLat: Double   // cached for the haversine

        init(lat: Double, lon: Double, frp: Double, isVIIRS: Bool, isNight: Bool, day: Int) {
            self.lat = lat; self.lon = lon; self.frp = frp
            self.isVIIRS = isVIIRS; self.isNight = isNight; self.day = day
            latR = lat * .pi / 180; lonR = lon * .pi / 180; cosLat = cos(latR)
        }
    }

    static func matrix(for detections: [FireDetection], grids: StaticGrids?) -> [Float] {
        let pts = detections.map { d in
            Point(lat: d.latitude, lon: d.longitude, frp: d.frp ?? 0, isVIIRS: d.sensor == .viirs,
                  isNight: d.dayNight != .day,
                  day: Int((d.acquiredAt!.timeIntervalSince1970 / 86_400).rounded(.down)))
        }
        let grid = Grid(pts)
        let viirsDays = Set(pts.lazy.filter(\.isVIIRS).map(\.day))
        let modisDays = Set(pts.lazy.filter { !$0.isVIIRS }.map(\.day))
        let n = WildfireClassifier.featureNames.count
        var x = [Float](repeating: -1, count: detections.count * n)

        // Every row depends only on its own detection and the (read-only) grid, so the rows
        // are filled in parallel. Each chunk writes to its own rows of `x`.
        x.withUnsafeMutableBufferPointer { x in
        Parallel.forEachChunk(of: detections.count) { range in
        for i in range {
            let d = detections[i]
            let p = pts[i]
            let mir = d.brightness, tir = d.brightness2
            let area = d.scan.flatMap { s in d.track.map { s * $0 } }
            let t = utcParts(d.acquiredAt!)
            let selfNight = p.isNight ? 1 : 0

            let c = grid.context(of: p)
            let s = grids?.lookup(lat: d.latitude, lon: d.longitude)
            let otherPresent = (p.isVIIRS ? modisDays : viirsDays).contains(p.day)

            let row: [Double?] = [
                p.isVIIRS ? 1 : 0,
                mir,
                tir,
                mir.flatMap { m in tir.map { m - $0 } },
                d.frp,
                d.frp.map { log1p(max($0, 0)) },
                d.frp.flatMap { f in area.map { f / $0 } },
                area,
                confidenceClass(d),
                d.dayNight == .day ? 1 : 0,
                Double(t.hour) + Double(t.minute) / 60,
                Double(t.month),
                Double(c.same - 1),                      // minus itself
                Double(c.other),
                c.otherMaxFRP,
                c.other > 0 ? 1 : 0,
                Double(c.all - 1),                       // minus itself
                c.allMaxFRP,                             // includes itself, as in training
                c.allSumFRP,                             // includes itself
                Double(c.prevDay),
                Double(c.night - selfNight),
                Double(c.dayTime - (1 - selfNight)),
                otherPresent ? 1 : 0,
                s?[0], s?[1], s?[2], s?[3], s?[4], s?[5],
            ]
            for (j, v) in row.enumerated() {
                if let v, !v.isNaN { x[i * n + j] = Float(v) }
            }
        }
        }
        }
        return x
    }

    /// Month, hour and minute of a moment in UTC, by arithmetic. It gives the same answer as
    /// a Gregorian calendar set to UTC, and is far quicker when asked 100,000 times.
    static func utcParts(_ date: Date) -> (month: Int, hour: Int, minute: Int) {
        let seconds = date.timeIntervalSince1970
        let day = (seconds / 86_400).rounded(.down)
        let secondOfDay = Int(seconds - day * 86_400)
        // Days since 1970 to a civil date (Howard Hinnant's algorithm).
        let z = Int(day) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let m = (5 * dayOfYear + 2) / 153
        return (m < 10 ? m + 3 : m - 9, secondOfDay / 3_600, secondOfDay / 60 % 60)
    }

    /// One scale for both sensors: 0 = low, 1 = nominal, 2 = high.
    /// MODIS 0-100 % is binned <30 / 30-79 / >=80 (MODIS C6 user guide).
    private static func confidenceClass(_ d: FireDetection) -> Double? {
        switch d.confidence {
        case .percent(let p):
            switch p {
            case 0...29: return 0
            case 30...79: return 1
            case 80...100: return 2
            default: return nil
            }
        case .category(let c): return Double(c.rank)
        case .unknown: return nil
        }
    }

    /// Buckets points by UTC day and a 0.05° lat/lon cell, for fast radius searches.
    fileprivate struct Grid {
        struct Key: Hashable { let day: Int, y: Int, x: Int }
        static let cell = 0.05
        let points: [Point]
        var buckets: [Key: [Int]] = [:]

        init(_ points: [Point]) {
            self.points = points
            for (i, p) in points.enumerated() {
                buckets[Key(day: p.day, y: Int((p.lat / Self.cell).rounded(.down)),
                            x: Int((p.lon / Self.cell).rounded(.down))), default: []].append(i)
            }
        }

        /// Neighbor counts around p, in one pass over the 5 km / two-day neighborhood
        /// (identical to separate radius searches; all distances are great-circle, inclusive).
        struct Context {
            var same = 0                                   // 2 km, same day, same sensor (incl. p)
            var other = 0, otherMaxFRP = 0.0               // 2 km, yesterday + today, other sensor
            var all = 0, allMaxFRP = 0.0, allSumFRP = 0.0  // 5 km, same day, both sensors (incl. p)
            var prevDay = 0                                // 5 km, yesterday only
            var night = 0, dayTime = 0                     // 5 km, yesterday + today (incl. p)
        }

        func context(of p: Point) -> Context {
            let near = 2 / HarmonizedFeatures.earthKm, far = 5 / HarmonizedFeatures.earthKm
            let dy = Int((5 / 111.19 / Self.cell).rounded(.up)) + 1
            let dx = min(Int((5 / (111.19 * max(p.cosLat, 0.01)) / Self.cell).rounded(.up)) + 1, Int(360 / Self.cell))
            let cy = Int((p.lat / Self.cell).rounded(.down)), cx = Int((p.lon / Self.cell).rounded(.down))

            var c = Context()
            for day in (p.day - 1)...p.day {
                let today = day == p.day
                for y in (cy - dy)...(cy + dy) {
                    for x in (cx - dx)...(cx + dx) {
                        guard let idx = buckets[Key(day: day, y: y, x: x)] else { continue }
                        for j in idx {
                            let q = points[j]
                            // Haversine, same formula as sklearn's BallTree(metric="haversine")
                            let s1 = sin((q.latR - p.latR) / 2), s2 = sin((q.lonR - p.lonR) / 2)
                            let angle = 2 * asin(min(1, sqrt(s1 * s1 + p.cosLat * q.cosLat * s2 * s2)))
                            guard angle <= far else { continue }
                            if q.isNight { c.night += 1 } else { c.dayTime += 1 }
                            if today {
                                c.all += 1; c.allMaxFRP = max(c.allMaxFRP, q.frp); c.allSumFRP += q.frp
                            } else {
                                c.prevDay += 1
                            }
                            guard angle <= near else { continue }
                            if q.isVIIRS == p.isVIIRS {
                                if today { c.same += 1 }
                            } else {
                                c.other += 1; c.otherMaxFRP = max(c.otherMaxFRP, q.frp)
                            }
                        }
                    }
                }
            }
            return c
        }
    }
}

// MARK: - Static grids

/// Land cover fractions (NLCD 2019) and 2017–2019 fire-history months on a 0.01° grid over
/// California, written by ml/build_static_grids.py. Outside the grid every value is missing.
/// File layout (little-endian): "EMSG", u32 version, u32 rows, u32 cols, u32 bands, f64 lat0,
/// f64 lon0, f64 step, then raw DEFLATE of uint8 bands (band-major, row-major).
nonisolated final class StaticGrids: Sendable {
    enum LoadError: Error { case badFile }

    private let rows: Int, cols: Int, bands: Int
    private let lat0: Double, lon0: Double, step: Double
    private let values: [UInt8]

    init(data: Data) throws {
        guard data.count > 44, data.prefix(4) == Data("EMSG".utf8) else { throw LoadError.badFile }
        func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) })) }
        func f64(_ o: Int) -> Double {
            Double(bitPattern: UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }))
        }
        guard u32(4) == 1 else { throw LoadError.badFile }
        rows = u32(8); cols = u32(12); bands = u32(16)
        lat0 = f64(20); lon0 = f64(28); step = f64(36)
        let raw = try (data.subdata(in: 44..<data.count) as NSData).decompressed(using: .zlib) as Data
        guard bands == 6, raw.count == rows * cols * bands else { throw LoadError.badFile }
        values = [UInt8](raw)
    }

    /// [forest, shrub, grass, ag, developed] as 0–1 fractions, then fire-history months.
    /// nil entries mean no data (ocean or outside the grid).
    func lookup(lat: Double, lon: Double) -> [Double?] {
        let r = Int(((lat - lat0) / step).rounded(.down)), c = Int(((lon - lon0) / step).rounded(.down))
        guard r >= 0, r < rows, c >= 0, c < cols else { return Array(repeating: nil, count: bands) }
        return (0..<bands).map { b in
            let v = values[(b * rows + r) * cols + c]
            if b == bands - 1 { return Double(v) }        // history months
            return v == 255 ? nil : Double(v) / 100
        }
    }
}

// MARK: - Forest

/// A scikit-learn random forest exported by ml/export_app_model.py.
/// File layout (little-endian): "EMRF", u32 version, u32 trees, u32 features, then per tree
/// u32 nodes and arrays of i16 feature (-1 = leaf), f64 threshold, i32 left, i32 right, f32 P(wildfire).
nonisolated final class EmberForest: Sendable {
    enum LoadError: Error { case badFile }

    private let feature: [Int16]
    private let threshold: [Double]
    private let left: [Int32]
    private let right: [Int32]
    private let prob: [Float]
    private let roots: [Int]

    init(data: Data) throws {
        guard data.count >= 16, data.prefix(4) == Data("EMRF".utf8) else { throw LoadError.badFile }
        var off = 4
        func read<T: FixedWidthInteger>(_: T.Type) -> T {
            defer { off += MemoryLayout<T>.size }
            return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self) })
        }
        func array<T>(_ n: Int, _: T.Type) -> [T] {
            defer { off += n * MemoryLayout<T>.size }
            return data.withUnsafeBytes { raw in
                (0..<n).map { raw.loadUnaligned(fromByteOffset: off + $0 * MemoryLayout<T>.size, as: T.self) }
            }
        }
        guard read(UInt32.self) == 1 else { throw LoadError.badFile }
        let trees = Int(read(UInt32.self))
        guard Int(read(UInt32.self)) == WildfireClassifier.featureNames.count else { throw LoadError.badFile }

        var f: [Int16] = [], t: [Double] = [], l: [Int32] = [], r: [Int32] = [], p: [Float] = [], roots: [Int] = []
        for _ in 0..<trees {
            guard off + 4 <= data.count else { throw LoadError.badFile }
            let n = Int(read(UInt32.self))
            guard off + n * 22 <= data.count else { throw LoadError.badFile }
            let base = Int32(f.count)
            roots.append(f.count)
            f += array(n, Int16.self)
            t += array(n, Double.self)
            l += array(n, Int32.self).map { $0 + base }   // make child indices global
            r += array(n, Int32.self).map { $0 + base }
            p += array(n, Float.self)
        }
        (feature, threshold, left, right, prob, self.roots) = (f, t, l, r, p, roots)
    }

    /// Mean P(wildfire) over all trees. Features are compared as Float, like scikit-learn.
    func predict(_ x: UnsafeBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for root in roots {
            var node = root
            while feature[node] >= 0 {
                node = Double(x[Int(feature[node])]) <= threshold[node] ? Int(left[node]) : Int(right[node])
            }
            sum += prob[node]
        }
        return sum / Float(roots.count)
    }
}
