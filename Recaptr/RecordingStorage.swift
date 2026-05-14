//
//  RecordingStorage.swift
//  Recaptr
//
//  Persists the user's chosen recording save folder via a
//  security-scoped bookmark in UserDefaults. Falls back to the
//  sandbox container when no folder is set or the saved folder
//  has become unavailable (volume unmounted, folder deleted).
//
//  Flow:
//    1. User clicks "Change…" → `pickFolder()` shows an NSOpenPanel
//    2. On OK, a `.withSecurityScope` bookmark is created and stored
//    3. On every launch, `init()` resolves the bookmark and calls
//       `startAccessingSecurityScopedResource()` — that scope stays
//       valid for the process lifetime
//    4. `Recorder.start()` requests the resolved URL via
//       `resolveSaveDirectory()`
//    5. If resolution fails at any step, the sandbox container is
//       used so a recording is never lost to a bad bookmark
//
//  Requires `com.apple.security.files.user-selected.read-write` in
//  the app's entitlements.
//

import Foundation
import Combine
import AppKit

@MainActor
final class RecordingStorage: ObservableObject {

    /// User-facing label for the current save location — last path
    /// component of the picked folder, or a sentinel for sandbox.
    @Published private(set) var displayLabel: String = "Default (sandbox)"

    /// Full path of the current save location, for UI tooltips.
    @Published private(set) var displayPath: String = ""

    /// True when a user-selected folder is in use, false on the
    /// sandbox fallback. UI exposes a Reset button only in the
    /// `true` case.
    @Published private(set) var hasUserLocation: Bool = false

    private let bookmarkKey = "com.OvertonForge.Recaptr.saveLocation.bookmark"
    private var securityScopedURL: URL?

    init() {
        resolveStoredBookmark()
    }

    // MARK: - Public API

    /// Present an NSOpenPanel to pick a folder. On OK, create and
    /// persist a security-scoped bookmark and begin access.
    /// Synchronous (uses `runModal()`); callers are expected to
    /// disable the button during recording so it can't fire
    /// mid-take.
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Recaptr Save Location"
        panel.prompt = "Use This Folder"
        panel.message = "Recaptr will write all new recordings into this folder."
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory,
                                                       in: .userDomainMask).first

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        adopt(url: url)
    }

    /// Drop the saved location and revert to the sandbox container.
    /// Existing recordings stay where they were; only new recordings
    /// change destination.
    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        hasUserLocation = false
        displayLabel = "Default (sandbox)"
        displayPath = ""
    }

    /// Resolve the directory a new recording should write into.
    /// Returns the user-picked folder if available and writable,
    /// otherwise the sandbox fallback. Creates the directory if
    /// missing.
    func resolveSaveDirectory() throws -> URL {
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

            securityScopedURL?.stopAccessingSecurityScopedResource()
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
                hasUserLocation = true
                displayLabel = url.lastPathComponent
                displayPath = url.path
            } else {
                // Couldn't begin access on a freshly-chosen folder.
                // Roll back to the sandbox default.
                resetToDefault()
            }
        } catch {
            // Bookmark creation failed; remain on whatever location
            // was active before this call.
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
            // Volume unmounted, folder deleted, or bookmark format
            // changed. Silently fall back to sandbox; user can
            // re-pick from the UI.
        }
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
