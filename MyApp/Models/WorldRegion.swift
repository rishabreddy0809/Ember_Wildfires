//  WorldRegion.swift
//  Sorts detections into about fifty named parts of the world, so the sidebar can say
//  where it is burning without needing a network lookup.
//
//  The regions are rough latitude/longitude boxes, checked in order. They are a way to
//  group points on screen. They are not borders, and near an edge a detection can land
//  in the neighbouring region.

import Foundation

nonisolated struct WorldRegion: Sendable {
    let name: String
    let continent: String

    /// (name, continent, west, south, east, north). The first box that contains a point wins.
    private static let boxes: [(String, String, Double, Double, Double, Double)] = [
        // North America
        ("Alaska and Yukon", "North America", -170, 54, -130, 72),
        ("California", "North America", -124.6, 32.4, -114.1, 42.0),
        ("Pacific Northwest", "North America", -125, 42, -110, 49.2),
        ("Western Canada", "North America", -130, 49, -95, 70),
        ("Southwest and Rockies", "North America", -120, 31.3, -102, 42),
        ("Central United States", "North America", -110, 29.5, -93, 49),
        ("Great Lakes and Northeast", "North America", -93, 36.5, -66, 47.5),
        ("Eastern Canada", "North America", -95, 45, -52, 63),
        ("US Southeast", "North America", -93, 24.5, -75, 36.5),
        ("Central America", "North America", -92.3, 7, -77, 18.3),
        ("Mexico", "North America", -118, 14.5, -86.5, 32.4),
        ("Caribbean", "North America", -85, 9.5, -59, 27),
        // South America
        ("Northern South America", "South America", -79.5, 1, -50, 13),
        ("Andes and Pacific Coast", "South America", -82, -30, -70, -13),
        ("Amazon Basin", "South America", -79.5, -13, -50, 1),
        ("Eastern Brazil", "South America", -50, -24, -34, 1),
        ("Chaco and Pantanal", "South America", -70, -30, -50, -13),
        ("Southern Cone", "South America", -76, -56, -48, -24),
        // Europe and the Mediterranean
        ("British Isles", "Europe", -11, 49.8, 2, 61),
        ("Iberia", "Europe", -10, 36, 3.3, 44),
        ("North Africa and Sahara", "Africa", -18, 16, 11.8, 37.4),
        ("Southern Europe", "Europe", 6, 34.8, 29, 46.5),
        ("Western Europe", "Europe", -6, 42, 16, 55.5),
        ("Northern Europe", "Europe", -25, 54.5, 31, 72),
        // Africa
        ("Madagascar", "Africa", 42.5, -26.5, 51, -11.5),
        ("West Africa", "Africa", -18, 3.5, 15, 16),
        ("Central Africa", "Africa", 8, -6, 32, 13),
        ("Middle East", "Asia", 42.6, 12.5, 60, 32),
        ("East Africa", "Africa", 32, -12, 52, 16),
        ("North Africa and Sahara", "Africa", -18, 13, 37, 34.8),
        ("South-Central Africa", "Africa", 10, -19, 42, -6),
        ("Southern Africa", "Africa", 10, -36, 42, -19),
        // Asia
        ("Middle East", "Asia", 26, 12, 48.5, 44),
        ("Middle East", "Asia", 48.5, 12, 63, 38),
        ("Central Asia", "Asia", 46, 35.5, 80, 51),
        ("Eastern Europe", "Europe", 16, 44, 60, 70),
        ("South Asia", "Asia", 60.5, 5, 94.5, 35.5),
        ("Philippines", "Asia", 116, 4.5, 127, 21),
        ("Indonesia and Malaysia", "Asia", 94, -11, 141, 7),
        ("Mainland Southeast Asia", "Asia", 94.5, 7, 101.5, 28.5),
        ("Mainland Southeast Asia", "Asia", 101.5, 7, 110, 23.3),
        ("Eastern China", "Asia", 97.5, 18, 123, 42),
        ("Japan and Korea", "Asia", 124.5, 30, 146, 42.5),
        ("Japan and Korea", "Asia", 139.3, 42.5, 146, 45.7),
        ("Western China and Tibet", "Asia", 78, 27.5, 97.5, 49),
        ("Manchuria and Amur", "Asia", 115, 42, 141, 54),
        ("Mongolia", "Asia", 87, 42, 115, 52),
        ("Siberia", "Asia", 60, 50, 115, 78),
        ("Russian Far East", "Asia", 115, 50, 180, 78),
        ("Russian Far East", "Asia", -180, 60, -168.5, 72),
        // Oceania
        ("New Guinea and Melanesia", "Oceania", 141, -12, 170, 0),
        ("Northern Australia", "Oceania", 112, -20, 154, -10),
        ("Eastern Australia", "Oceania", 138, -44, 154.5, -20),
        ("Western Australia", "Oceania", 112, -36, 138, -20),
        ("New Zealand", "Oceania", 165, -48, 179, -34),
    ]

    /// Every region once, in the order it first appears, plus a catch-all at the end.
    static let all: [WorldRegion] = {
        var seen = Set<String>()
        var out: [WorldRegion] = []
        for b in boxes where seen.insert(b.0).inserted { out.append(WorldRegion(name: b.0, continent: b.1)) }
        out.append(WorldRegion(name: "Islands and open ocean", continent: "Elsewhere"))
        return out
    }()

    private static let boxRegion: [Int] = {
        let index = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.name, $0) })
        return boxes.map { index[$0.0]! }
    }()

    /// Index into `all` for a coordinate.
    static func index(latitude: Double, longitude: Double) -> Int {
        for (i, b) in boxes.enumerated() where longitude >= b.2 && longitude <= b.4 && latitude >= b.3 && latitude <= b.5 {
            return boxRegion[i]
        }
        return all.count - 1
    }

    /// The region of every detection, in the same order. Runs off the main thread.
    @concurrent
    static func assign(_ detections: [FireDetection]) async -> [Int] {
        detections.map { index(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
