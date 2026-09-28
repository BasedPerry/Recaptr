//
//  SessionNaming.swift
//  Recaptr
//
//  Series and episode file naming. Recordings are renamed after the take.
//

import Foundation

nonisolated enum SessionNaming {

    /// En dash with spaces: reads well in Finder and never appears in generated titles.
    static let separator = " – "

    /// Makes `text` safe as a file name. Colons become a look-alike (U+A789)
    /// so titles still read naturally; leading dots go; 80 characters max.
    static func sanitize(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "\u{A789}")
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

    /// One more than the highest "Ep N" already in the series folder.
    static func nextEpisodeNumber(existing fileNames: [String], series: String) -> Int {
        let prefix = sanitize(series) + separator + "Ep "
        let numbers = fileNames.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count).prefix { $0.isNumber })
        }
        return (numbers.max() ?? 0) + 1
    }

    /// The typed episode, or "Ep N" plus a generated title when there is one.
    static func episode(typed: String, number: Int, generatedTitle: String?) -> String {
        let typed = sanitize(typed)
        if !typed.isEmpty { return typed }
        let title = generatedTitle.map(sanitize) ?? ""
        return title.isEmpty ? "Ep \(number)" : "Ep \(number)\(separator)\(title)"
    }

    /// Series and episode joined by `separator`.
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
