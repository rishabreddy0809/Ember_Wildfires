//  FireQuery.swift
//  Describes what to download: which area, which dates, and which FIRMS products.

import Foundation
import MapKit

/// A latitude/longitude box. FIRMS wants it as "west,south,east,north".
nonisolated struct GeoBounds: Codable, Hashable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    /// The AREA_COORDINATES part of a FIRMS URL.
    var firmsString: String {
        [west, south, east, north].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// nil if valid, otherwise a reason it is not.
    var validationError: String? {
        guard (-180...180).contains(west), (-180...180).contains(east) else { return "Longitude must be between -180 and 180." }
        guard (-90...90).contains(south), (-90...90).contains(north) else { return "Latitude must be between -90 and 90." }
        guard west < east else { return "West must be less than East." }
        guard south < north else { return "South must be less than North." }
        return nil
    }

    /// The same box as a MapKit rectangle, used to zoom the map to the area.
    var mapRect: MKMapRect {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
        return MKMapRect(x: min(nw.x, se.x), y: min(nw.y, se.y),
                         width: abs(se.x - nw.x), height: abs(se.y - nw.y))
    }

    /// Converts a visible map rectangle back into a latitude/longitude box.
    init(mapRect r: MKMapRect) {
        let nw = MKMapPoint(x: r.minX, y: r.minY).coordinate
        let se = MKMapPoint(x: r.maxX, y: r.maxY).coordinate
        west = max(-180, nw.longitude); east = min(180, se.longitude)
        north = min(90, nw.latitude); south = max(-90, se.latitude)
    }

    init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west; self.south = south; self.east = east; self.north = north
    }

    static let california = GeoBounds(west: -124.48, south: 32.53, east: -114.13, north: 42.01)
}

/// Built-in regions for the area picker.
nonisolated struct AreaPreset: Identifiable, Hashable, Sendable {
    let name: String
    let bounds: GeoBounds
    var id: String { name }

    static let all: [AreaPreset] = [
        AreaPreset(name: "California", bounds: .california),
        AreaPreset(name: "Pacific Northwest", bounds: GeoBounds(west: -124.8, south: 41.9, east: -116.4, north: 49.0)),
        AreaPreset(name: "American Southwest", bounds: GeoBounds(west: -120.0, south: 31.3, east: -103.0, north: 37.0)),
        AreaPreset(name: "Contiguous United States", bounds: GeoBounds(west: -125.0, south: 24.4, east: -66.9, north: 49.4)),
        AreaPreset(name: "Western Canada", bounds: GeoBounds(west: -139.1, south: 48.3, east: -101.0, north: 60.0)),
        AreaPreset(name: "Amazon Basin", bounds: GeoBounds(west: -75.0, south: -15.0, east: -45.0, north: 5.0)),
        AreaPreset(name: "Mediterranean", bounds: GeoBounds(west: -10.0, south: 34.0, east: 37.0, north: 46.0)),
        AreaPreset(name: "Southeast Australia", bounds: GeoBounds(west: 140.0, south: -39.2, east: 153.7, north: -28.0)),
    ]
}

/// FIRMS processing level.
/// Near real-time (NRT) arrives within about 3 hours of the satellite overpass.
/// Standard (SP) is the archive, which is reprocessed science-quality data that arrives months later.
nonisolated enum FIRMSProduct: String, Codable, CaseIterable, Identifiable, Sendable {
    case nearRealTime = "NRT"
    case standard = "SP"
    var id: String { rawValue }
    var label: String { self == .nearRealTime ? "Near Real-Time" : "Standard (Archive)" }
}

/// Which satellite's VIIRS instrument to use. All three carry the same 375 m sensor.
nonisolated enum VIIRSSatellite: String, Codable, CaseIterable, Identifiable, Sendable {
    case noaa20 = "NOAA20"
    case noaa21 = "NOAA21"
    case suomiNPP = "SNPP"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .noaa20: "NOAA-20"
        case .noaa21: "NOAA-21"
        case .suomiNPP: "Suomi NPP"
        }
    }
}

/// Everything needed to repeat a download. It is saved with the cache so you know what the cached data covers.
nonisolated struct FireQuery: Codable, Hashable, Sendable {
    var areaName: String = "California"
    var bounds: GeoBounds = .california
    /// First UTC day to include.
    var startDate: Date = FireQuery.utcDay(daysAgo: 1)
    /// Number of days to include, starting at startDate. Longer ranges are split into
    /// several requests, because FIRMS allows at most 5 days per request.
    var dayCount: Int = 2
    var product: FIRMSProduct = .nearRealTime
    var viirsSatellite: VIIRSSatellite = .noaa20

    static let maxDayCount = 10

    /// FIRMS SOURCE names, from the FIRMS area API documentation.
    var modisSource: String { "MODIS_\(product.rawValue)" }                         // MODIS_NRT / MODIS_SP
    var viirsSource: String { "VIIRS_\(viirsSatellite.rawValue)_\(product.rawValue)" } // e.g. VIIRS_NOAA20_NRT

    func source(for sensor: Sensor) -> String { sensor == .modis ? modisSource : viirsSource }

    /// The last UTC day included.
    var endDate: Date { FireQuery.utc.date(byAdding: .day, value: dayCount - 1, to: startDate) ?? startDate }

    /// Splits the date range into pieces of at most 5 days (the FIRMS limit per request).
    var dayChunks: [(start: Date, days: Int)] {
        var chunks: [(Date, Int)] = []
        var remaining = dayCount
        var cursor = startDate
        while remaining > 0 {
            let n = min(5, remaining)
            chunks.append((cursor, n))
            cursor = FireQuery.utc.date(byAdding: .day, value: n, to: cursor) ?? cursor
            remaining -= n
        }
        return chunks
    }

    // MARK: UTC date helpers (FIRMS dates are always UTC)

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func utcDay(daysAgo: Int) -> Date {
        let today = utc.startOfDay(for: Date())
        return utc.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    /// Formats a date as "YYYY-MM-DD" in UTC, as FIRMS expects.
    static func firmsDateString(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
