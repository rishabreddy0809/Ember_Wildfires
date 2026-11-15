//  DetectionCache.swift
//  Saves the last successful download to disk so the app still works offline.
//
//  The cache keeps the CSV text exactly as FIRMS sent it, not the parsed detections.
//  A worldwide download is around 100,000 rows; as CSV that is a few megabytes and is
//  parsed again in about a second at launch, where the parsed form was far larger.
//
//  Location (sandboxed app):
//  ~/Library/Containers/<bundle id>/Data/Library/Application Support/Ember/last-download.plist

import Foundation

/// What gets saved: the CSV pages for each sensor, the query that produced them, and when.
nonisolated struct CachedSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var query: FireQuery
    var modisPages: [String]
    var viirsPages: [String]
}

nonisolated enum DetectionCache {
    private static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Ember", directoryHint: .isDirectory)
    }
    static var fileURL: URL { folder.appending(path: "last-download.plist") }
    /// The format used before the app went worldwide. Removed when found.
    private static var legacyURL: URL { folder.appending(path: "last-download.json") }

    /// Saves the snapshot on a background thread. The write is atomic, so a crash can't leave a half-written file.
    @concurrent
    static func save(_ snapshot: CachedSnapshot) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// Loads the snapshot, or returns nil if there is none or it can't be read.
    @concurrent
    static func load() async -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(CachedSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
