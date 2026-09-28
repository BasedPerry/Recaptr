//
//  RecordingStorage.swift
//  Recaptr
//
//  Remembers the save folder with a security-scoped bookmark. Falls
//  back to the sandbox container when the folder isn't available.
//

import Foundation
import Combine
import AppKit

@MainActor
final class RecordingStorage: ObservableObject {

    @Published private(set) var displayLabel: String = "Default (sandbox)"

    /// Full path, for tooltips.
    @Published private(set) var displayPath: String = ""

    /// False when on the sandbox fallback.
    @Published private(set) var hasUserLocation: Bool = false

    private let bookmarkKey = "com.OvertonForge.Recaptr.saveLocation.bookmark"
    private let usesDefaultKey = "com.OvertonForge.Recaptr.saveLocation.usesDefault"
    private var securityScopedURL: URL?

    init() {
        resolveStoredBookmark()
    }

    // MARK: - Public API

    /// True until a folder has been chosen (or the default picked in
    /// Settings), so the first recording can ask where to save.
    var needsFolderChoice: Bool {
        let defaults = UserDefaults.standard
        return defaults.data(forKey: bookmarkKey) == nil
            && !defaults.bool(forKey: usesDefaultKey)
            && !defaults.bool(forKey: "RecaptrUITesting")
    }

    /// Shows a folder picker and saves a bookmark. Runs modally, so
    /// callers disable it while recording. Returns false if cancelled.
    @discardableResult
    func pickFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Recaptr Save Location"
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Recaptr saves recordings. You can change this in Settings."
        panel.directoryURL = Self.userMoviesFolder

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return false }

        adopt(url: url)
        return hasUserLocation
    }

    /// Reverts to the sandbox container for new recordings.
    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.set(true, forKey: usesDefaultKey)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        hasUserLocation = false
        displayLabel = "Default (sandbox)"
        displayPath = ""
    }

    /// The chosen folder if it's writable, otherwise the sandbox folder.
    func resolveSaveDirectory() throws -> URL {
        // UI tests always record into the sandbox container.
        if UserDefaults.standard.bool(forKey: "RecaptrUITesting") {
            return try Self.sandboxDefault()
        }
        if let url = securityScopedURL,
           FileManager.default.isWritableFile(atPath: url.path) {
            return url
        }
        return try Self.sandboxDefault()
    }

    // MARK: - Internal

    private func adopt(url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            UserDefaults.standard.removeObject(forKey: usesDefaultKey)

            securityScopedURL?.stopAccessingSecurityScopedResource()
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
                hasUserLocation = true
                displayLabel = url.lastPathComponent
                displayPath = url.path
            } else {
                resetToDefault()
            }
        } catch {
            // Keep the current location.
        }
    }

    private func resolveStoredBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
                hasUserLocation = true
                displayLabel = url.lastPathComponent
                displayPath = url.path
                if isStale {
                    // Refresh so the next launch resolves cleanly.
                    adopt(url: url)
                }
            }
        } catch {
            // Folder gone or volume unmounted. Use the sandbox.
        }
    }

    /// The real ~/Movies. Inside the sandbox, FileManager returns the
    /// container's copy instead.
    private static var userMoviesFolder: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Movies", isDirectory: true)
    }

    private static func sandboxDefault() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("Recaptr", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
