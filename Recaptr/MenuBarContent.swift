//
//  MenuBarContent.swift
//  Recaptr
//

import SwiftUI

/// Menu for the menu bar item: recording controls mid-take, otherwise
/// Start Recording, Recent Recordings and Show Recaptr.
struct MenuBarContent: View {
    @EnvironmentObject var vm: MainViewModel

    /// Settings → Recording → "Show in menu bar always".
    static let alwaysKey = "RecaptrMenuBarAlways"

    var body: some View {
        if vm.isRecording {
            MenuElapsed(clock: vm.clock)
                .font(.system(size: 13, weight: .medium))

            Divider()

            Button(RecordingControlsPill.shortcutHelp("Drop Marker", key: "⌘B",
                                                      global: vm.hotKeyLabel(for: .dropMarker))) {
                vm.dropMarker()
            }

            Button("Show Recaptr") { vm.bringForward() }

            Divider()

            Button(RecordingControlsPill.shortcutHelp("Stop Recording", key: "⌘R",
                                                      global: vm.hotKeyLabel(for: .toggleRecording))) {
                Task { await vm.stopRecording() }
            }
        } else {
            Button(RecordingControlsPill.shortcutHelp("Start Recording", key: "⌘R",
                                                      global: vm.hotKeyLabel(for: .toggleRecording))) {
                vm.perform(.toggleRecording)
            }
            .disabled(vm.selectedMainSource == nil)

            RecentRecordingsMenu(vm: vm, recent: vm.recentTakes)

            Divider()

            Button("Show Recaptr") { vm.bringForward() }
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

/// Red dot and elapsed time while recording, a plain record icon
/// otherwise. Observes only the clock so the app's scenes don't rebuild
/// every second. Nothing blinks.
struct MenuBarLabel: View {
    @ObservedObject var clock: RecordingClock
    let isRecording: Bool

    var body: some View {
        if isRecording {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.red)
                Text(clock.formattedElapsed)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .accessibilityLabel("Recaptr, recording, \(clock.formattedElapsed)")
        } else {
            Image(systemName: "record.circle")
                .accessibilityLabel("Recaptr")
        }
    }
}
