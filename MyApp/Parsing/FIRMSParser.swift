//  FIRMSParser.swift
//  Converts FIRMS CSV text into FireDetection values.
//
//  Columns are found by their header name, not by position, so MODIS and VIIRS files
//  (which have different columns) and any extra columns FIRMS adds later are all handled.
//
//  Verified headers (live FIRMS files, Nov 2026):
//   MODIS: latitude,longitude,brightness,scan,track,acq_date,acq_time,satellite,confidence,version,bright_t31,frp,daynight
//   VIIRS: latitude,longitude,bright_ti4,scan,track,acq_date,acq_time,satellite,confidence,version,bright_ti5,frp,daynight
//  The area API may also include an "instrument" column, and MODIS standard data a "type" column.
//  Both are read when they are present.

import Foundation

nonisolated enum FIRMSParser {

    /// Parses one CSV response. Rows without a valid latitude/longitude are counted in `skipped` instead of being dropped silently.
    /// `@concurrent` makes this run on a background thread, so large files don't freeze the interface.
    @concurrent
    static func parse(csv: String, sensor: Sensor, source: String) async -> (detections: [FireDetection], skipped: Int) {
        let (header, rows) = CSVParser.parse(csv)
        let names = header.map { $0.lowercased() }
        let index = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        var detections: [FireDetection] = []
        detections.reserveCapacity(rows.count)
        var skipped = 0

        for row in rows {
            // Looks up a cell by column name, trying each alias in order.
            func cell(_ keys: String...) -> String? {
                for k in keys {
                    if let i = index[k], i < row.count {
                        let v = row[i].trimmingCharacters(in: .whitespaces)
                        return v
                    }
                }
                return nil
            }
            func number(_ keys: String...) -> Double? {
                for k in keys { if let i = index[k], i < row.count, let d = Double(row[i].trimmingCharacters(in: .whitespaces)) { return d } }
                return nil
            }

            guard let lat = number("latitude"), let lon = number("longitude"),
                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                skipped += 1
                continue
            }

            let acqDate = cell("acq_date") ?? ""
            let acqTime = normalizedTime(cell("acq_time") ?? "")

            let columns = zip(header, row).map { CSVColumn(name: $0, value: $1) }

            detections.append(FireDetection(
                id: UUID(),
                sensor: sensor,
                source: source,
                latitude: lat,
                longitude: lon,
                brightness: number("brightness", "bright_ti4"),
                brightness2: number("bright_t31", "bright_ti5"),
                scan: number("scan"),
                track: number("track"),
                acqDate: acqDate,
                acqTime: acqTime,
                acquiredAt: acquisitionDate(date: acqDate, time: acqTime),
                satellite: cell("satellite") ?? "",
                instrument: cell("instrument"),
                confidence: DetectionConfidence(raw: cell("confidence") ?? "", sensor: sensor),
                version: cell("version") ?? "",
                frp: number("frp"),
                dayNight: DayNight(firmsValue: cell("daynight") ?? ""),
                type: cell("type").flatMap { Int($0) },
                allColumns: columns
            ))
        }
        return (detections, skipped)
    }

    /// acq_time is HHMM in UTC. Leading zeros are sometimes missing ("45" means 00:45), so pad to 4 digits.
    static func normalizedTime(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return raw }
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// Joins "2026-11-06" and "0947" into a Date (UTC).
    static func acquisitionDate(date: String, time: String) -> Date? {
        let d = date.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3, time.count == 4,
              let hh = Int(time.prefix(2)), let mm = Int(time.suffix(2)) else { return nil }
        return FireQuery.utc.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: hh, minute: mm))
    }
}
