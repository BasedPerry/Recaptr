//
//  RecentTakes.swift
//  Recaptr
//
//  The last few recordings, newest first. Kept as bookmarks so they
//  still open after a relaunch in the sandbox and follow a Finder rename.
//  The save folder each take was recorded into is bookmarked too: the
//  sandbox needs it to read the take's .fcpxml and to rename or move it,
//  even after the user picks a different save folder.
//

import Foundation
import Combine

@MainActor
final class RecentTakes: ObservableObject {

    static let limit = 10
    static let storageKey = "RecaptrRecentTakes"
    static let rootsKey = "RecaptrRecentTakeRoots"

    /// Newest first. Only files that still exist.
    @Published private(set) var urls: [URL] = []

    private let defaults: UserDefaults
    /// Test runs keep the list in memory so they never touch real settings.
    private let persists: Bool
    private var accessing: Set<URL> = []
    /// Save folders the listed takes live in, held open for the session.
    private var roots: [URL] = []

    init(defaults: UserDefaults = .standard, persists: Bool = !TestHooks.isOn) {
        self.defaults = defaults
        self.persists = persists
        if persists { load() }
    }

    /// `root` is the save folder the take was recorded into.
    func add(_ url: URL, root: URL? = nil) {
        urls = Self.adding(url, to: urls)
        if let root, !roots.contains(where: { $0.standardizedFileURL.path == root.standardizedFileURL.path }) {
            roots.append(Self.ownAccess(to: root) ?? root)
        }
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

    /// Opens this list's own access to `root`, so it outlives the save
    /// folder's when the user picks another one.
    private static func ownAccess(to root: URL) -> URL? {
        var stale = false
        guard let data = try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
              let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
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
        // Only folders that still hold a listed take.
        let kept = roots.filter { root in
            urls.contains { $0.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") }
        }
        let rootBookmarks = kept.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(rootBookmarks, forKey: Self.rootsKey)
    }

    private func load() {
        for data in defaults.array(forKey: Self.rootsKey) as? [Data] ?? [] {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if root.startAccessingSecurityScopedResource() {
                accessing.insert(root)
                roots.append(root)
            }
        }
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
