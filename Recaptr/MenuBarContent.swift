//
//  MenuBarContent.swift
//  Recaptr
//

import SwiftUI

/// Dropdown content for the menu bar recording indicator. The
/// containing `MenuBarExtra` in RecaptrApp inserts this item only
/// while `vm.isRecording` is true.
///
/// Surfaces three actions reachable from anywhere on macOS without
/// bringing the Recaptr window forward: drop a clip marker, show
/// the main window, or stop recording.
struct MenuBarContent: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Text("Recording · \(formattedElapsed)")
            .font(.system(size: 13, weight: .medium))

        Divider()

        Button("Drop Marker (⌘B, or ⌃⌥⌘B from any app)") {
            vm.dropMarker()
        }

        Button("Show Recaptr") {
            bringRecaptrForward()
        }

        Divider()

        Button("Stop Recording (⌘R)") {
            Task { await vm.stopRecording() }
        }
    }

    private var formattedElapsed: String {
        let t = Int(vm.recordingElapsed)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Activate Recaptr and surface its main window. Called from the
    /// "Show Recaptr" menu bar item.
    private func bringRecaptrForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
