//
//  RecaptrApp.swift
//  Recaptr
//
//  Created by bp on 1/28/26.
//

import SwiftUI

@main
struct RecaptrApp: App {

    // Phase 2 (2026-05-09): swapped @StateObject DeviceCatalog for
    // @StateObject MainViewModel. The catalog now lives inside
    // MainViewModel (single source of truth), and MainViewModel
    // triggers `await catalog.refresh()` from its own init — so the
    // .task modifier on the root view is no longer needed here.
    @StateObject private var vm = MainViewModel()

    var body: some Scene {
        WindowGroup {
            // Phase 6 — ContentViewNext is the QuickTime-style layout:
            // preview edge-to-edge, floating glass pills, fade-on-idle
            // chrome. ContentView (the older form-style layout) is
            // preserved in the codebase; flip the call below to
            // `ContentView()` if you want to A/B test.
            ContentViewNext()
                .environmentObject(vm)
        }
        // Phase 6 — hidden title bar so the preview surface extends
        // edge-to-edge under the traffic lights, matching QuickTime
        // Player's borderless feel. The traffic light buttons stay
        // visible (macOS draws them on top automatically); ContentViewNext
        // keeps the top-left area free of UI so they don't overlap chrome.
        .windowStyle(.hiddenTitleBar)

        // Phase 6.4 — menu bar recording indicator.
        // MenuBarExtra is auto-inserted only while vm.isRecording is
        // true. Label is a red circle + the elapsed-time readout so
        // the user gets "yes, I'm still recording, here's how long"
        // at a glance from anywhere in macOS. Dropdown menu carries
        // Drop Marker, Show Recaptr, and Stop Recording so the user
        // can act on the recording without bringing the window back.
        // `isInserted` is a bidirectional binding, but we don't want
        // MenuBarExtra to write back into vm.isRecording (a user
        // hiding the menu bar item shouldn't stop the recording).
        // Read-only binding ignores writes.
        MenuBarExtra(isInserted: Binding(
            get: { vm.isRecording },
            set: { _ in /* read-only by design */ }
        )) {
            MenuBarContent().environmentObject(vm)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.red)
                Text(menuBarElapsed)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.menu)
    }

    /// Format the menu-bar elapsed string. Mirrors ContentViewNext's
    /// telemetry-pill format so the two readouts are identical when
    /// both are visible.
    private var menuBarElapsed: String {
        let t = Int(vm.recordingElapsed)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
