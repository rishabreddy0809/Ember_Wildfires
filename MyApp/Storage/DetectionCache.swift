//  DetectionCache.swift
//  Saves the last successful download to disk so the map still works offline.
//
//  Location (sandboxed app):
//  ~/Library/Containers/<bundle id>/Data/Library/Application Support/Ember/last-download.json

import Foundation

/// What gets saved: the raw detections, the query that produced them, and when they were downloaded.
nonisolated struct CachedSnapshot: Codable, Sendable {
    var fetchedAt: Date
    var query: FireQuery
    var detections: [FireDetection]
}

nonisolated enum DetectionCache {
    static var fileURL: URL {
        let base = URL.applicationSupportDirectory.appending(path: "Ember", directoryHint: .isDirectory)
        return base.appending(path: "last-download.json")
    }

    /// Saves the snapshot on a background thread. The write is atomic, so a crash can't leave a half-written file.
    @concurrent
    static func save(_ snapshot: CachedSnapshot) async throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// Loads the snapshot, or returns nil if there is none or it can't be read.
    @concurrent
    static func load() async -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedSnapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
