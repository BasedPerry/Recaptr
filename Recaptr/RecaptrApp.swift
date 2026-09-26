//
//  RecaptrApp.swift
//  Recaptr
//

import SwiftUI

@main
struct RecaptrApp: App {

    /// Shared view model. Owns the device catalog, capture services,
    /// recorder, audio mixer, and all published UI state. Triggers
    /// `await catalog.refresh()` from its own init.
    @StateObject private var vm = MainViewModel()

    var body: some Scene {
        WindowGroup {
            ContentViewNext()
                .environmentObject(vm)
        }
        // Hidden title bar so the preview surface extends edge-to-edge
        // under the traffic lights. macOS still draws the traffic
        // light buttons on top; ContentViewNext keeps that corner
        // free of chrome to avoid overlap.
        .windowStyle(.hiddenTitleBar)

        // Menu bar recording indicator. Auto-inserted only while
        // `vm.isRecording` is true. Label is a red dot plus the
        // elapsed-time readout. Dropdown menu carries Drop Marker,
        // Show Recaptr, and Stop Recording so the user can act on
        // the recording without bringing the app window forward.
        //
        // `isInserted` is a bidirectional binding by API contract,
        // but treating it as read-only here prevents a user-driven
        // menu-bar-hide from accidentally stopping the recording.
        // Standard macOS Settings window: Recaptr > Settings… (⌘,) and
        // the gear button in the main window both open it.
        Settings {
            SettingsView()
                .environmentObject(vm)
        }

        MenuBarExtra(isInserted: Binding(
            get: { vm.isRecording },
            set: { _ in }
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

    /// Format the menu-bar elapsed string. Matches the in-window
    /// telemetry pill so both readouts are identical when visible.
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
