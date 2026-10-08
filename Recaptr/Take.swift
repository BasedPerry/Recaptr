//
//  Take.swift
//  Recaptr
//
//  A finished recording: its file, series and markers. Loads from the
//  `.fcpxml` beside the `.mov`, so any take can be renamed, not just the last.
//

import Foundation

struct Take: Equatable {
    var url: URL
    var series: String
    var markers: [FinalCutMarkers.Contents.Marker]

    /// The `.fcpxml` beside the recording.
    var sidecarURL: URL { Self.sidecar(for: url) }

    static func sidecar(for movURL: URL) -> URL {
        movURL.deletingPathExtension().appendingPathExtension("fcpxml")
    }

    /// The episode part of the file name ("Ep 1 – Title"), or the whole
    /// name for takes without a series.
    var episode: String {
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = series + SessionNaming.separator
        return !series.isEmpty && name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    /// Reads the take from its sidecar. Without one it has no markers and
    /// no series. The series is the event name, which Recaptr sets only
    /// for takes in a series.
    static func load(_ movURL: URL) -> Take {
        guard let data = try? Data(contentsOf: sidecar(for: movURL)),
              let contents = FinalCutMarkers.read(data) else {
            return Take(url: movURL, series: "", markers: [])
        }
        let name = movURL.deletingPathExtension().lastPathComponent
        let event = contents.eventName ?? ""
        let inSeries = !event.isEmpty && name.hasPrefix(SessionNaming.sanitize(event) + SessionNaming.separator)
        return Take(url: movURL, series: inSeries ? SessionNaming.sanitize(event) : "", markers: contents.markers)
    }

    /// The take with a new episode name and marker titles. Blank titles
    /// keep the old one. Doesn't touch the disk.
    func renamed(episode: String, markerTitles: [String]) -> Take? {
        let cleanEpisode = SessionNaming.sanitize(episode)
        guard !cleanEpisode.isEmpty else { return nil }
        var take = self
        for index in take.markers.indices where index < markerTitles.count {
            let title = markerTitles[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { take.markers[index].title = title }
        }
        let base = series.isEmpty ? cleanEpisode : SessionNaming.baseName(series: series, episode: cleanEpisode)
        // "Name (2)" already carries this base; keep it rather than move to "Name (3)".
        let current = url.deletingPathExtension().lastPathComponent
        let keepsName = current == base
            || (current.hasPrefix(base + " (") && current.hasSuffix(")")
                && Int(current.dropFirst(base.count + 2).dropLast()) != nil)
        if !keepsName {
            take.url = url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("mov")
        }
        return take
    }

    /// Applies a rename on disk: moves the `.mov` to the new name (never
    /// over another file) and rewrites the sidecar. Returns the take as saved.
    static func apply(from old: Take, to new: Take) async throws -> Take {
        var saved = new
        if new.url != old.url {
            let folder = old.url.deletingLastPathComponent()
            saved.url = SessionNaming.uniqueURL(in: folder, base: new.url.deletingPathExtension().lastPathComponent, ext: "mov")
            try FileManager.default.moveItem(at: old.url, to: saved.url)
            // The old sidecar points at the old name; it's rewritten below.
            try? FileManager.default.removeItem(at: old.sidecarURL)
        }
        try await FinalCutMarkers.writeIfNeeded(for: saved.url,
                                                markers: saved.markers.map { ($0.title, $0.seconds) },
                                                eventName: saved.series.isEmpty ? nil : saved.series)
        return saved
    }
}
