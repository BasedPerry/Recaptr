//
//  SelfCaptureHint.swift
//  Recaptr
//
//  When the captured screen is the one Recaptr's window is on: a note
//  that Recaptr is left out of the recording, and an option to get the
//  window out of the way while recording. Capture itself is unchanged.
//

import SwiftUI
import AppKit

enum SelfCapture {
    /// Settings key for "Hide Recaptr while recording".
    static let hideKey = "RecaptrHideWhileRecording"

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain }
    }

    /// The display Recaptr's main window is on.
    static var windowDisplay: CGDirectDisplayID? {
        mainWindow?.screen?.displayID
    }

    /// Minimizes the window when recording starts and brings it back when
    /// it stops. Only for a screen capture of the window's own display.
    @MainActor
    static func follow(isRecording: Bool, source: VideoSource?) {
        guard TestHooks.preferences.bool(forKey: hideKey), let window = mainWindow else { return }
        if isRecording {
            guard source?.kind == .screenDisplay, source?.displayID == windowDisplay else { return }
            window.miniaturize(nil)
        } else if window.isMiniaturized {
            window.deminiaturize(nil)
        }
    }
}

struct SelfCaptureHint: View {
    @AppStorage(SelfCapture.hideKey, store: TestHooks.preferences) private var hideWhileRecording = false

    var body: some View {
        HStack(spacing: 12) {
            Label("Recaptr is on this screen. It's left out of the recording.", systemImage: "eye.slash")
                .font(BrandFont.body(weight: .medium, size: 12).swiftUI)
            Toggle("Hide Recaptr while recording", isOn: $hideWhileRecording)
                .toggleStyle(.checkbox)
                .font(BrandFont.body(weight: .regular, size: 12).swiftUI)
                .help("Minimizes Recaptr when recording starts. It comes back when you stop, or from the menu bar.")
                .accessibilityIdentifier("hideWhileRecordingToggle")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .recaptrGlass()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selfCaptureHint")
    }
}
