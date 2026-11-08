//  CSVParser.swift
//  A small general-purpose CSV reader. It handles quoted fields, commas inside quotes,
//  doubled quotes ("") and both \n and \r\n line endings.
//  It knows nothing about fires. FIRMSParser uses it to read FIRMS files.

import Foundation

nonisolated enum CSVParser {
    /// Returns the header row and the data rows.
    static func parse(_ text: String) -> (header: [String], rows: [[String]]) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            // Skip blank lines
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = pending {
            pending = iterator.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" { field.unicodeScalars.append("\""); pending = iterator.next() }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": endField()
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                endRow()
            case "\n": endRow()
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }

        guard let header = rows.first else { return ([], []) }
        return (header.map { $0.trimmingCharacters(in: .whitespaces) }, Array(rows.dropFirst()))
    }
}
