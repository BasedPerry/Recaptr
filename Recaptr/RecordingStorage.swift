//
//  RecordingStorage.swift
//  Recaptr
//
//  Phase 7 sneak (2026-05-11): user-selected save location.
//
//  Before this, every recording landed at:
//    ~/Library/Containers/com.OvertonForge.Recaptr/Data/Library/
//      Application Support/Recaptr/Recordings/
//  …which the sandbox keeps writable but the user has to navigate via
//  cmd-shift-G to retrieve. After the Phase 4 + Phase 5 stress tests,
//  Brandon was manually copying every recording out to
//  /Volumes/UGREEN 4TB/Footage/RDR2/Recaptr/ for analysis. Daily-pain
//  friction, easily fixed.
//
//  Pattern:
//    1. User clicks "Change…" → NSOpenPanel for a folder
//    2. We get a security-scoped bookmark (`.withSecurityScope`),
//       persist it in UserDefaults
//    3. On init (every launch), resolve the bookmark, call
//       startAccessingSecurityScopedResource() — that scope stays
//       valid for the process lifetime
//    4. Recorder.start() takes the resolved URL as its base directory
//    5. If resolution fails (volume unmounted, folder deleted), we
//       fall back to the sandbox container path — old behavior
//
//  Entitlement: com.apple.security.files.user-selected.read-write must
//  be in Recaptr.entitlements (read-only was Phase 4's default).
//

import Foundation
import Combine
import AppKit

@MainActor
final class RecordingStorage: ObservableObject {

    /// User-facing label for the current save location. Either the
    /// last path component of the picked folder, or a sentinel for the
    /// sandbox fallback.
    @Published private(set) var displayLabel: String = "Default (sandbox)"

    /// Full path of the current save location for UI tooltips.
    @Published private(set) var displayPath: String = ""

    /// True when a user-selected folder is in use, false when we're on
    /// the sandbox fallback. UI exposes "Reset" only in the true case.
    @Published private(set) var hasUserLocation: Bool = false

    private let bookmarkKey = "com.OvertonForge.Recaptr.saveLocation.bookmark"
    private var securityScopedURL: URL?

    init() {
        resolveStoredBookmark()
    }

    // MARK: - Public API

    /// Show NSOpenPanel for a folder; on OK, create + persist a
    /// security-scoped bookmark and start access. Synchronous —
    /// NSOpenPanel.runModal() blocks main while the sheet is up,
    /// which is the standard pattern (and we disable the button
    /// during recording so it can't fire mid-take).
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Choose Recaptr Save Location"
        panel.prompt = "Use This Folder"
        panel.message = "Recaptr will write all new recordings into this folder."
        // Sensible default — most users record video/screen content into
        // either Movies or an external drive. Movies is the closer
        // shorthand for "where my video lives."
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory,
                                                       in: .userDomainMask).first

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        adopt(url: url)
    }

    /// Drop the saved location, revert to sandbox container. Old
    /// recordings stay where they were; only new recordings change
    /// destination.
    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        hasUserLocation = false
        displayLabel = "Default (sandbox)"
        displayPath = ""
        print("RecordingStorage: reset to sandbox default")
    }

    /// Resolve the save directory for a new recording. Returns the
    /// user-picked folder if available + accessible, otherwise the
    /// sandbox fallback. Creates the directory if missing.
    func resolveSaveDirectory() throws -> URL {
        if let url = securityScopedURL {
            // Verify writability — picked folder may have become
            // read-only or unmounted between resolution and now.
            if FileManager.default.isWritableFile(atPath: url.path) {
                return url
            }
            print("RecordingStorage: user-picked folder no longer writable, falling back to sandbox")
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

            // Release prior scope, start the new one.
            securityScopedURL?.stopAccessingSecurityScopedResource()
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
                hasUserLocation = true
                displayLabel = url.lastPathComponent
                displayPath = url.path
                print("RecordingStorage: adopted user-selected folder \(url.path)")
            } else {
                // startAccessing failed — shouldn't happen for a freshly
                // chosen folder via NSOpenPanel, but if it does, drop
                // back to default.
                print("RecordingStorage: startAccessingSecurityScopedResource returned false for \(url.path)")
                resetToDefault()
            }
        } catch {
            print("RecordingStorage: failed to create bookmark for \(url.path): \(error)")
        }
    }

    private func resolveStoredBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            // No prior selection — sandbox default is correct.
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
                    // Refresh the bookmark so next launch resolves clean.
                    print("RecordingStorage: bookmark for \(url.path) was stale, refreshing")
                    adopt(url: url)
                } else {
                    print("RecordingStorage: resolved user-selected folder \(url.path)")
                }
            } else {
                print("RecordingStorage: startAccessing returned false on launch — folder unavailable?")
            }
        } catch {
            // Volume unmounted, folder deleted, bookmark format change —
            // any of these surfaces as a thrown error. Quietly fall
            // back to sandbox; user can re-pick from the UI.
            print("RecordingStorage: failed to resolve stored bookmark: \(error.localizedDescription)")
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
