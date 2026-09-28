//
//  DeviceCatalog.swift
//  Recaptr
//
//  Lists displays, windows, cameras and microphones.
//

import Foundation
import Combine
import AVFoundation
import CoreAudio
import ScreenCaptureKit
import AppKit

@MainActor
final class DeviceCatalog: ObservableObject {
    @Published var videoSources: [VideoSource] = []
    @Published var audioSources: [AudioSource] = []

    /// Reloads all sources. Safe to call repeatedly.
    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadShareableContent() }
            group.addTask { await self.loadCamerasAndMics() }
        }

        print("DeviceCatalog: \(videoSources.count) video source(s), \(audioSources.count) audio source(s)")
        // Debug only: the list includes every window title on the Mac.
        #if DEBUG
        for s in videoSources {
            print("  · [\(s.kind.rawValue)] \(s.name)  (id=\(s.id))")
        }
        for s in audioSources {
            print("  · [audio] \(s.name)")
        }
        #endif
    }

    private func loadCamerasAndMics() async {
        let camDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        let micDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        // USB cameras and capture cards only. Continuity devices are left out:
        // selecting the iPhone camera on macOS 27 crashes the app (see README).
        // On macOS 27 the iPhone camera also reports as `.external`.
        let continuity = [kAudioDeviceTransportTypeContinuityCaptureWired,
                          kAudioDeviceTransportTypeContinuityCaptureWireless].map { Int32(bitPattern: $0) }
        let cams = camDiscovery.devices.filter { !$0.isContinuityCamera && !continuity.contains($0.transportType) }
        let mics = micDiscovery.devices.filter { !continuity.contains($0.transportType) }

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

        // Core Audio adds transient "CADefaultDeviceAggregate" devices when an
        // engine opens the default output. They're never real inputs.
        let micSources = mics
            .filter { !$0.localizedName.hasPrefix("CADefaultDeviceAggregate") }
            .map { AudioSource(id: $0.uniqueID, name: $0.localizedName) }

        await MainActor.run {
            self.videoSources.removeAll(where: { $0.kind == .camera })
            self.videoSources.append(contentsOf: camSources)
            self.audioSources = micSources.sorted(by: { $0.name < $1.name })
        }
    }

    private func loadShareableContent() async {
        // SCShareableContent triggers the Screen Recording prompt, so wait until
        // access is granted. The view model asks when a screen source is picked.
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
            let myBundleID = Bundle.main.bundleIdentifier
            for w in content.windows {
                // Skip system surfaces, helper windows and Recaptr's own.
                guard let app = w.owningApplication,
                      app.bundleIdentifier != myBundleID,
                      w.windowLayer == 0,
                      w.frame.width >= 200, w.frame.height >= 120,
                      let title = w.title, !title.isEmpty,
                      // Background agents own titled windows too.
                      NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular
                else { continue }
                let appName = app.applicationName
                screenSources.append(VideoSource(
                    id: "window:\(w.windowID)",
                    name: "Window — \(appName): \(title)",
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
            // No permission yet. The view model shows the banner.
        }
    }

    /// Display name from `NSScreen`, since `SCDisplay` has no localized name.
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
