//  SecretsLoader.swift
//  Reads your FIRMS MAP_KEY from Secrets.plist, which is bundled with the app.
//
//  The key is never written in the code. Secrets.plist is listed in .gitignore so it
//  stays off GitHub. Secrets.example.plist (in the project root) is the template.

import Foundation

nonisolated enum SecretsLoader {
    static let plistName = "Secrets"
    static let keyName = "FIRMS_MAP_KEY"
    /// The value in the template. It means the real key has not been added yet.
    static let placeholder = "PASTE_YOUR_MAP_KEY_HERE"

    /// The MAP_KEY, or nil if it is missing or still the placeholder.
    static func mapKey(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: plistName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist[keyName] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != placeholder else { return nil }
        return key
    }

    /// Shows only the last 4 characters, for the Settings window.
    static func masked(_ key: String) -> String {
        String(repeating: "•", count: max(0, key.count - 4)) + key.suffix(4)
    }
}
