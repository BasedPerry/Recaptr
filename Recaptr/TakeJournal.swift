//
//  TakeJournal.swift
//  Recaptr
//
//  A small hidden file beside a take while it records: its series,
//  episode and markers so far. If Recaptr quits or crashes before the
//  take is finished, the next launch uses it to finish the take.
//

import Foundation

nonisolated struct TakeJournal: Codable, Equatable {
    var series: String
    var episode: String
    var markerSeconds: [Double]

    static let suffix = ".recaptr-take"

    /// `folder/.<take name>.recaptr-take`. Hidden so it never shows in Finder.
    static func url(for movURL: URL) -> URL {
        let name = "." + movURL.deletingPathExtension().lastPathComponent + suffix
        return movURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    func save(for movURL: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(for: movURL), options: .atomic)
    }

    static func load(for movURL: URL) -> TakeJournal? {
        guard let data = try? Data(contentsOf: url(for: movURL)) else { return nil }
        return try? JSONDecoder().decode(TakeJournal.self, from: data)
    }

    static func remove(for movURL: URL) {
        try? FileManager.default.removeItem(at: url(for: movURL))
    }

    /// Takes in `folder` that were never finished, oldest first. A journal
    /// whose take is gone is deleted. `excluding` is the take recording now.
    static func leftovers(in folder: URL, excluding recording: URL? = nil) -> [(movURL: URL, journal: TakeJournal)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [(movURL: URL, journal: TakeJournal)] = []
        for name in names.sorted() where name.hasPrefix(".") && name.hasSuffix(suffix) {
            let base = String(name.dropFirst().dropLast(suffix.count))
            let mov = folder.appendingPathComponent(base).appendingPathExtension("mov")
            if let recording, mov.standardizedFileURL == recording.standardizedFileURL { continue }
            guard fm.fileExists(atPath: mov.path) else {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
                continue
            }
            if let journal = load(for: mov) {
                found.append((mov, journal))
            }
        }
        return found
    }
}
