//
//  DeviceCatalog.swift
//  Recaptr
//
//  Enumerates available capture sources: ScreenCaptureKit displays
//  and windows for screen sources, AVCaptureDevice for cameras
//  and microphones. The catalog is the single source of truth used
//  by the MainViewModel + UI source switcher.
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

    /// Refresh both video and audio source lists. Safe to call
    /// repeatedly (e.g. on device hotplug or app activation).
    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadShareableContent() }
            group.addTask { await self.loadCamerasAndMics() }
        }

        print("DeviceCatalog: \(videoSources.count) video source(s), \(audioSources.count) audio source(s)")
        for s in videoSources {
            print("  · [\(s.kind.rawValue)] \(s.name)  (id=\(s.id))")
        }
        for s in audioSources {
            print("  · [audio] \(s.name)")
        }
    }

    private func loadCamerasAndMics() async {
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
        // Calling SCShareableContent without permission fires the
        // Screen Recording prompt. Only enumerate once access is
        // granted; the view model asks for it the first time the user
        // picks a Window or Screen source.
        guard CGPreflightScreenCaptureAccess() else { return }
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
            // Screen Recording permission not yet granted; the
            // viewmodel surfaces a permission banner from
            // CGPreflightScreenCaptureAccess on its own path.
        }
    }

    /// Resolve a human-readable name for a `CGDirectDisplayID` by
    /// matching against `NSScreen.screens`. `SCDisplay.localizedName`
    /// was deprecated/removed in shipping ScreenCaptureKit; this is
    /// the canonical workaround.
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
