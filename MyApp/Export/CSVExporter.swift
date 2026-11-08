//  CSVExporter.swift
//  Writes the combined MODIS + VIIRS detections to one CSV file, ready for Python.
//
//  Every column has the same meaning for both sensors, and missing values are left
//  empty so pandas reads them as NaN. Load it with:
//      df = pd.read_csv("fires.csv", parse_dates=["acq_datetime_utc"])
//  The "sensor" column records where each detection came from. Confidence is split into
//  two columns: `confidence_percent` (MODIS) and `confidence_category` (VIIRS).

import SwiftUI
import UniformTypeIdentifiers

nonisolated enum CSVExporter {
    static let header = [
        "sensor", "source", "latitude", "longitude",
        "brightness_k", "brightness_column", "bright_secondary_k", "bright_secondary_column",
        "scan_km", "track_km", "acq_date", "acq_time", "acq_datetime_utc",
        "satellite", "instrument", "confidence_raw", "confidence_percent", "confidence_category",
        "version", "frp_mw", "daynight", "type",
    ]

    static func csv(for detections: [FireDetection]) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        func n(_ d: Double?) -> String { d.map { String($0) } ?? "" }

        var lines = [header.joined(separator: ",")]
        lines.reserveCapacity(detections.count + 1)
        for d in detections {
            let rawConfidence = d.allColumns.first { $0.name.lowercased() == "confidence" }?.value ?? ""
            var percent = "", category = ""
            switch d.confidence {
            case .percent(let p): percent = String(p)
            case .category(let c): category = c.rawValue
            case .unknown: break
            }
            let when: String = d.acquiredAt.map { iso.string(from: $0) } ?? ""
            let dayNight: String = d.dayNight == .unknown ? "" : d.dayNight.rawValue
            let type: String = d.type.map { String($0) } ?? ""
            var fields: [String] = [d.sensor.rawValue, d.source, String(d.latitude), String(d.longitude)]
            fields += [n(d.brightness), d.brightnessColumnName, n(d.brightness2), d.brightness2ColumnName]
            fields += [n(d.scan), n(d.track), d.acqDate, d.acqTime, when]
            fields += [d.satellite, d.instrument ?? "", rawConfidence, percent, category]
            fields += [d.version, n(d.frp), dayNight, type]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a field only if it contains a comma, a quote, or a line break.
    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Wraps the CSV text so SwiftUI's `.fileExporter` can save it.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
