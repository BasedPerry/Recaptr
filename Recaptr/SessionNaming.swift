//
//  SessionNaming.swift
//  Recaptr
//
//  Series / Episode naming for recordings. A series (the game, the
//  show) gets its own folder under the save folder, and each recording
//  is named "Series – Episode". The episode is what the user typed, or,
//  when left blank, "Ep N" plus an optional generated title
//  ("Fire Emblem – Ep 4 – Fortuna Falls").
//
//  Recordings are written under a provisional name and renamed once
//  the take has stopped, so the episode can be typed (or generated)
//  after recording.
//

import Foundation

nonisolated enum SessionNaming {

    /// Separator between name parts. An en dash with spaces reads well
    /// in Finder and Final Cut and never appears in generated titles.
    static let separator = " – "

    /// Make `text` safe as a file or folder name: no slashes or colons,
    /// no leading dots, single spaces, at most 80 characters.
    static func sanitize(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return cleaned
    }

    /// Folder for a series inside the save folder.
    static func seriesFolder(root: URL, series: String) -> URL {
        root.appendingPathComponent(sanitize(series), isDirectory: true)
    }

    /// Next auto episode number: one more than the highest "Ep N"
    /// already in the folder for this series.
    static func nextEpisodeNumber(existing fileNames: [String], series: String) -> Int {
        let prefix = sanitize(series) + separator + "Ep "
        let numbers = fileNames.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count).prefix { $0.isNumber })
        }
        return (numbers.max() ?? 0) + 1
    }

    /// Episode text for a recording: the typed episode if there is
    /// one, otherwise "Ep N", with a generated title when available.
    static func episode(typed: String, number: Int, generatedTitle: String?) -> String {
        let typed = sanitize(typed)
        if !typed.isEmpty { return typed }
        let title = generatedTitle.map(sanitize) ?? ""
        return title.isEmpty ? "Ep \(number)" : "Ep \(number)\(separator)\(title)"
    }

    /// "Series – Episode".
    static func baseName(series: String, episode: String) -> String {
        sanitize(series) + separator + sanitize(episode)
    }

    /// `folder/base.ext`, or `base (2).ext`, `base (3).ext`... if taken.
    static func uniqueURL(in folder: URL, base: String, ext: String,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
