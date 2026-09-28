//
//  MenuBarContent.swift
//  Recaptr
//

import SwiftUI

/// Menu for the menu bar recording indicator, shown only while recording.
struct MenuBarContent: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        MenuElapsed(clock: vm.clock)
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

    private func bringRecaptrForward() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

/// "Recording · 12:34", observing only the recording clock.
private struct MenuElapsed: View {
    @ObservedObject var clock: RecordingClock

    var body: some View {
        Text("Recording · \(clock.formattedElapsed)")
            .font(.system(size: 13, weight: .medium))
    }
}

/// Red dot and elapsed time. Observes only the clock so the app's
/// scenes don't rebuild every second.
struct MenuBarLabel: View {
    @ObservedObject var clock: RecordingClock

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .foregroundStyle(.red)
            Text(clock.formattedElapsed)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}
