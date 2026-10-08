//
//  RecentTakes.swift
//  Recaptr
//
//  The last few recordings, newest first. Kept as bookmarks so they
//  still open after a relaunch in the sandbox and follow a Finder rename.
//

import Foundation
import Combine

@MainActor
final class RecentTakes: ObservableObject {

    static let limit = 10
    static let storageKey = "RecaptrRecentTakes"

    /// Newest first. Only files that still exist.
    @Published private(set) var urls: [URL] = []

    private let defaults: UserDefaults
    /// Test runs keep the list in memory so they never touch real settings.
    private let persists: Bool
    private var accessing: Set<URL> = []

    init(defaults: UserDefaults = .standard, persists: Bool = !UserDefaults.standard.bool(forKey: "RecaptrUITesting")) {
        self.defaults = defaults
        self.persists = persists
        if persists { load() }
    }

    func add(_ url: URL) {
        urls = Self.adding(url, to: urls)
        save()
    }

    /// After a rename, keeps the take in its place in the list.
    func replace(_ old: URL, with new: URL) {
        guard let index = urls.firstIndex(of: old) else { return add(new) }
        urls[index] = new
        urls = Self.deduplicated(urls)
        save()
    }

    /// Drops takes that were moved or deleted.
    func prune() {
        let kept = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard kept != urls else { return }
        urls = kept
        save()
    }

    // MARK: - List rules

    static func adding(_ url: URL, to list: [URL]) -> [URL] {
        Array(deduplicated([url] + list).prefix(limit))
    }

    static func deduplicated(_ list: [URL]) -> [URL] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - Storage

    private func save() {
        guard persists else { return }
        let bookmarks = urls.compactMap { url -> Data? in
            (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        defaults.set(bookmarks, forKey: Self.storageKey)
    }

    private func load() {
        let stored = defaults.array(forKey: Self.storageKey) as? [Data] ?? []
        var resolved: [URL] = []
        for data in stored {
            var stale = false
            let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
            guard let url else { continue }
            // Held for the session so the take can be opened and renamed.
            if !accessing.contains(url), url.startAccessingSecurityScopedResource() {
                accessing.insert(url)
            }
            if FileManager.default.fileExists(atPath: url.path) { resolved.append(url) }
        }
        urls = Array(Self.deduplicated(resolved).prefix(Self.limit))
        if urls.count != stored.count { save() }
    }
}
