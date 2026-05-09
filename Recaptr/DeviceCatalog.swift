//
//  DeviceCatalog.swift
//  Recaptr
//
//  Phase 1 (2026-05-09): lifted from Dev/BackupCapture/Sources/DeviceCatalog.swift.
//  Already includes the SCDisplay.localizedName → NSScreen mapping fix
//  applied earlier on 2026-05-09 against shipping macOS Tahoe.
//
//  Diagnostic printf added at end of refresh() to preserve the visibility
//  the Phase 0 CaptureDeviceManager.refreshDevices() printf provided
//  (which retired in Phase 1 in favor of this catalog).
//

import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import AppKit

@MainActor
final class DeviceCatalog: ObservableObject {
    @Published var videoSources: [VideoSource] = []
    @Published var audioSources: [AudioSource] = []

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadShareableContent() }
            group.addTask { await self.loadCamerasAndMics() }
        }

        // Phase 0 → Phase 1 visibility: print what the catalog sees.
        // Format-catalog detail (the "20 formats" line from Phase 0) is
        // intentionally omitted here — it returns in Phase 3 when the
        // encoder needs it.
        print("DeviceCatalog: \(videoSources.count) video source(s), \(audioSources.count) audio source(s)")
        for s in videoSources {
            print("  · [\(s.kind.rawValue)] \(s.name)  (id=\(s.id))")
        }
        for s in audioSources {
            print("  · [audio] \(s.name)")
        }
    }

    private func loadCamerasAndMics() async {
        // Phase 2 (2026-05-09): patched from deprecated `devices(for:)`
        // to the AVCaptureDevice.DiscoverySession pattern (the same
        // shape Phase 0's CaptureDeviceManager used). Resolves the
        // macOS 10.15 deprecation warnings that surfaced in Phase 1.
        let camDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let micDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let cams = camDiscovery.devices
        let mics = micDiscovery.devices

        let camSources = cams.map {
            VideoSource(
                id: "camera:\($0.uniqueID)",
                name: "Camera — \($0.localizedName)",
                kind: .camera,
                displayID: nil,
                windowID: nil,
                cameraUniqueID: $0.uniqueID
            )
        }

        let micSources = mics.map {
            AudioSource(id: $0.uniqueID, name: $0.localizedName)
        }

        await MainActor.run {
            self.videoSources.removeAll(where: { $0.kind == .camera })
            self.videoSources.append(contentsOf: camSources)
            self.audioSources = micSources.sorted(by: { $0.name < $1.name })
        }
    }

    private func loadShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var screenSources: [VideoSource] = []

            for d in content.displays {
                screenSources.append(VideoSource(
                    id: "display:\(d.displayID)",
                    name: "Screen — \(Self.displayName(for: d.displayID))",
                    kind: .screenDisplay,
                    displayID: d.displayID,
                    windowID: nil,
                    cameraUniqueID: nil
                ))
            }
            for w in content.windows {
                guard let appName = w.owningApplication?.applicationName else { continue }
                screenSources.append(VideoSource(
                    id: "window:\(w.windowID)",
                    name: "Window — \(appName) #\(w.windowID)",
                    kind: .screenWindow,
                    displayID: nil,
                    windowID: w.windowID,
                    cameraUniqueID: nil
                ))
            }

            await MainActor.run {
                self.videoSources.removeAll(where: { $0.kind != .camera })
                self.videoSources.append(contentsOf: screenSources.sorted(by: { $0.name < $1.name }))
            }
        } catch {
            // Permission not granted yet; ignore.
            // Phase 5 will surface a proper error path when ScreenCaptureKit
            // becomes load-bearing for the main source.
        }
    }

    /// Resolve a human-readable name for a `CGDirectDisplayID`.
    ///
    /// `SCDisplay` no longer exposes `localizedName` in shipping
    /// ScreenCaptureKit (it was deprecated/removed at some point
    /// between Aug 2025 and shipping macOS Tahoe). The canonical
    /// path is to match the display ID against `NSScreen.screens`
    /// and pull `NSScreen.localizedName`, which has existed since
    /// macOS 10.15.
    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? CGDirectDisplayID) == displayID
        }) {
            return screen.localizedName
        }
        return "Display \(displayID)"
    }
}
