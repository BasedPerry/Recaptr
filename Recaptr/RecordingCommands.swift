//
//  RecordingCommands.swift
//  Recaptr
//
//  The Recording menu: every RecaptrAction, with its in-app shortcut.
//  Anything in a Mac menu can also be remapped in System Settings →
//  Keyboard → Keyboard Shortcuts → App Shortcuts.
//

import SwiftUI

struct RecordingCommands: View {
    @ObservedObject var vm: MainViewModel

    private var isCamera: Bool { vm.selectedMainSource?.kind == .camera }

    var body: some View {
        Button(vm.isRecording ? "Stop Recording" : "Start Recording") {
            vm.perform(.toggleRecording)
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!vm.isRecording && vm.selectedMainSource == nil)

        Button("Drop Marker") { vm.perform(.dropMarker) }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!vm.isRecording)

        Divider()

        Button("Window") { vm.perform(.sourceWindow) }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(vm.isRecording)
        Button("Screen") { vm.perform(.sourceScreen) }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(vm.isRecording)
        Button("Capture Card") { vm.perform(.sourceCaptureCard) }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(vm.isRecording)

        Divider()

        Toggle("Listen to Game Audio", isOn: $vm.gameMonitorEnabled)
            .disabled(!isCamera)
        Toggle("Listen to Mic", isOn: $vm.micMonitorEnabled)
            .disabled(!vm.hasMic)

        Divider()

        Button("Open Last Take") { vm.perform(.openLastTake) }
            .disabled(vm.lastTake == nil && vm.recentTakes.urls.isEmpty)
        Button("Show or Hide Recaptr") { vm.perform(.toggleWindow) }

        Divider()

        SettingsLink {
            Text("Keys That Work From Any App…")
        }
    }
}
