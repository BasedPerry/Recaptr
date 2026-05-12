//
//  MenuBarContent.swift
//  Recaptr
//
//  Phase 6.4 — menu bar dropdown content for the Recaptr status item.
//  The item is only inserted into the menu bar while recording (driven
//  by `MenuBarExtra(isInserted: $vm.isRecording, ...)` in RecaptrApp).
//
//  Why this exists. The biggest confidence gap during a long session
//  is "did I actually start recording?" or "is it still recording?"
//  when the user has ⌘-Tabbed away. A small red dot + elapsed-time
//  readout in the menu bar answers both questions at a glance, and
//  the dropdown lets the user drop a marker or stop recording without
//  having to bring the Recaptr window back to the foreground.
//

import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        // Live status line. Updates each second via vm.recordingElapsed.
        Text("Recording · \(formattedElapsed)")
            .font(.system(size: 13, weight: .medium))

        Divider()

        Button("Drop Marker (⌘B)") {
            dropMarker()
        }

        Button("Show Recaptr") {
            bringRecaptrForward()
        }

        Divider()

        // Tagged with "stop.fill" semantic — confirms the action even
        // if the user opens the menu while ⌘-Tabbed in another app.
        Button("Stop Recording (⌘R)") {
            Task { await vm.stopRecording() }
        }
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let t = Int(vm.recordingElapsed)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func dropMarker() {
        // Phase 6.5 — real marker. vm.dropMarker() handles the
        // not-recording guard, the markers array, and the status
        // line update. Same call as the in-app button.
        vm.dropMarker()
    }

    /// Activates the Recaptr app and surfaces its main window. Called
    /// when the user picks "Show Recaptr" from the menu bar dropdown
    /// — useful when they've ⌘-Tabbed away and want to come back to
    /// the app surface.
    private func bringRecaptrForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
