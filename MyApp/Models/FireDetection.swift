//  FireDetection.swift
//  The data model for one satellite fire detection (one row of a FIRMS CSV).
//
//  Every detection keeps its sensor (MODIS or VIIRS), the typed values the app
//  uses, and an exact copy of every column FIRMS returned, so no data is lost.

import Foundation
import CoreLocation

/// The two instrument families this app downloads.
nonisolated enum Sensor: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case modis = "MODIS"
    case viirs = "VIIRS"

    var id: String { rawValue }

    /// Nominal pixel size at the center of the swath (nadir).
    var nominalResolution: String {
        switch self {
        case .modis: "1 km"
        case .viirs: "375 m"
        }
    }
}

/// VIIRS reports confidence as a category instead of a number.
nonisolated enum VIIRSConfidence: String, Codable, CaseIterable, Hashable, Sendable {
    case low, nominal, high

    /// FIRMS uses either full words ("nominal") or single letters ("n"), depending on the product.
    init?(firmsValue: String) {
        switch firmsValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "l", "low": self = .low
        case "n", "nominal": self = .nominal
        case "h", "high": self = .high
        default: return nil
        }
    }

    /// 0 = low, 1 = nominal, 2 = high. Used when drawing the confidence meter.
    var rank: Int {
        switch self {
        case .low: 0
        case .nominal: 1
        case .high: 2
        }
    }
}

/// Confidence works differently for each sensor:
/// MODIS gives a percentage (0 to 100), and VIIRS gives low, nominal, or high.
nonisolated enum DetectionConfidence: Codable, Hashable, Sendable {
    case percent(Int)                 // MODIS
    case category(VIIRSConfidence)    // VIIRS
    case unknown(String)              // Anything unexpected is kept exactly as written

    /// Reads the raw CSV text using the rule for the given sensor.
    init(raw: String, sensor: Sensor) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch sensor {
        case .modis:
            if let value = Int(trimmed) { self = .percent(value) } else { self = .unknown(trimmed) }
        case .viirs:
            if let value = VIIRSConfidence(firmsValue: trimmed) { self = .category(value) } else { self = .unknown(trimmed) }
        }
    }

    var displayText: String {
        switch self {
        case .percent(let p): "\(p)%"
        case .category(let c): c.rawValue.capitalized
        case .unknown(let s): s.isEmpty ? "—" : s
        }
    }
}

/// D = daytime, N = nighttime, as FIRMS reports it.
nonisolated enum DayNight: String, Codable, Hashable, Sendable {
    case day = "D"
    case night = "N"
    case unknown = "?"

    init(firmsValue: String) {
        self = DayNight(rawValue: firmsValue.trimmingCharacters(in: .whitespaces).uppercased()) ?? .unknown
    }

    var label: String {
        switch self {
        case .day: "Day"
        case .night: "Night"
        case .unknown: "Unknown"
        }
    }
}

/// One original CSV cell. The column order is kept the same as in the file.
nonisolated struct CSVColumn: Codable, Hashable, Sendable {
    let name: String
    let value: String
}

/// One fire detection: a single satellite pixel that was flagged as burning.
nonisolated struct FireDetection: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    // Where it came from
    let sensor: Sensor
    /// The FIRMS SOURCE name it was downloaded from, for example "MODIS_NRT" or "VIIRS_NOAA20_NRT".
    let source: String

    // Location (center of the pixel, not necessarily the exact fire location)
    let latitude: Double
    let longitude: Double

    /// Main brightness temperature in kelvin.
    /// MODIS: "brightness" (channel 21/22). VIIRS: "bright_ti4" (I-4 channel).
    let brightness: Double?
    /// Secondary brightness temperature in kelvin.
    /// MODIS: "bright_t31" (channel 31). VIIRS: "bright_ti5" (I-5 channel).
    let brightness2: Double?

    /// Pixel size along the scan direction (km). Pixels grow toward the edge of the swath.
    let scan: Double?
    /// Pixel size along the track direction (km).
    let track: Double?

    /// Acquisition date and time exactly as FIRMS wrote them ("2026-11-06" and "0947", in UTC).
    let acqDate: String
    let acqTime: String
    /// The same moment as a real date (UTC), or nil if it could not be read.
    let acquiredAt: Date?

    /// Satellite code: MODIS "T" = Terra, "A" = Aqua. VIIRS "N" = Suomi NPP, "N20" = NOAA-20, "N21" = NOAA-21.
    let satellite: String
    /// "instrument" column. Some FIRMS outputs include it and some do not.
    let instrument: String?
    let confidence: DetectionConfidence
    /// Processing version, for example "6.1NRT" or "2.0NRT".
    let version: String
    /// Fire radiative power in megawatts.
    let frp: Double?
    let dayNight: DayNight
    /// MODIS standard (archive) data only: 0 = vegetation fire, 1 = volcano, 2 = other static land source, 3 = offshore.
    let type: Int?

    /// Every column FIRMS returned for this row, unchanged.
    let allColumns: [CSVColumn]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Readable name for the satellite code.
    var satelliteName: String {
        switch satellite.uppercased() {
        case "T": "Terra"
        case "A": "Aqua"
        case "N": "Suomi NPP"
        case "N20", "1": "NOAA-20"
        case "N21": "NOAA-21"
        default: satellite
        }
    }

    /// Name of the main brightness column, which differs between sensors.
    var brightnessColumnName: String { sensor == .modis ? "brightness" : "bright_ti4" }
    var brightness2ColumnName: String { sensor == .modis ? "bright_t31" : "bright_ti5" }
}
