//  FIRMSClient.swift
//  Downloads CSV text from the NASA FIRMS "area" API.
//
//  URL format (from https://firms.modaps.eosdis.nasa.gov/api/area/):
//    /api/area/csv/[MAP_KEY]/[SOURCE]/[AREA_COORDINATES]/[DAY_RANGE]/[DATE]
//  • AREA_COORDINATES = west,south,east,north
//  • DAY_RANGE = 1 to 5 (at most 5 days per request)
//  • DATE = YYYY-MM-DD, the first day. The response covers DATE through DATE + DAY_RANGE − 1.
//
//  This file only handles networking. Turning the CSV into FireDetection values is done in FIRMSParser.swift.

import Foundation

nonisolated struct FIRMSClient: Sendable {
    let mapKey: String
    var session: URLSession = .shared

    static let baseURL = URL(string: "https://firms.modaps.eosdis.nasa.gov/api/area/csv")!

    /// Builds the request URL for one source and one chunk of at most 5 days.
    func url(source: String, bounds: GeoBounds, days: Int, start: Date) -> URL {
        Self.baseURL
            .appending(path: mapKey)
            .appending(path: source)
            .appending(path: bounds.firmsString)
            .appending(path: String(days))
            .appending(path: FireQuery.firmsDateString(start))
    }

    /// Downloads one sensor for the whole query. Date ranges longer than 5 days become
    /// several requests, which run one after another so FIRMS is not hit all at once.
    /// Returns the CSV text of each chunk.
    func fetchCSV(for sensor: Sensor, query: FireQuery) async throws -> [String] {
        var pages: [String] = []
        for chunk in query.dayChunks {
            try Task.checkCancellation()
            let url = url(source: query.source(for: sensor), bounds: query.bounds, days: chunk.days, start: chunk.start)
            pages.append(try await fetch(url))
        }
        return pages
    }

    /// Makes a single GET request, then checks the response for FIRMS error messages.
    private func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FIRMSError.from(error)
        }

        let body = String(decoding: data, as: UTF8.self)
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // FIRMS answers a bad key with: "Invalid MAP_KEY." (HTTP 400). Checked against the live API.
        if firstLine.localizedCaseInsensitiveContains("invalid map_key") { throw FIRMSError.invalidKey }
        // Over the limit: "...exceeded your transaction/time limit..."
        if body.localizedCaseInsensitiveContains("exceeded") || status == 429 {
            throw FIRMSError.rateLimited(retryAfter: nil)
        }
        guard (200..<300).contains(status) else {
            throw FIRMSError.server(status: status, message: firstLine.isEmpty ? "No message" : String(firstLine.prefix(200)))
        }
        // A valid response always starts with a CSV header row. Anything else is an error message.
        guard firstLine.lowercased().hasPrefix("latitude") else {
            throw FIRMSError.unexpectedResponse(firstLine.isEmpty ? "(empty response)" : firstLine)
        }
        return body
    }
}
