//
//  SettingsView.swift
//  Recaptr
//
//  App-wide settings. Per-source tuning lives in the source sidebar.
//

import SwiftUI
import AVFoundation
import AppKit

struct SettingsView: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        TabView {
            Tab("Recording", systemImage: "record.circle") {
                RecordingSettingsTab()
            }
            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutsSettingsTab()
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsTab()
            }
        }
        .environmentObject(vm)
        .frame(width: 540)
    }
}

// MARK: - Recording

private struct RecordingSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel
    @AppStorage(MenuBarContent.alwaysKey, store: TestHooks.preferences) private var menuBarAlways = false

    var body: some View {
        Form {
            Section {
                Picker("Start with", selection: $vm.startSource) {
                    ForEach(MainViewModel.StartSource.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show in menu bar always", isOn: $menuBarAlways)
                    .accessibilityIdentifier("menuBarAlwaysToggle")
            } header: {
                Text("Launch")
            } footer: {
                Text("Recaptr is always in the menu bar while recording, with the time.")
            }

            Section {
                Picker("Name markers", selection: namingBinding) {
                    ForEach(MarkerNaming.allCases) { mode in
                        Text(mode.label).tag(mode)
                            .disabled(mode == .appleIntelligence && !MarkerNamer.isAvailable)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("markerNamingPicker")
                Toggle("Play a sound when a marker lands", isOn: $vm.markerSoundEnabled)
                    .accessibilityIdentifier("markerSoundToggle")
            } header: {
                Text("Markers")
            } footer: {
                Text(namingFooter)
            }

            Section("Last recording") {
                if let url = vm.lastRecordedFile {
                    LabeledContent("File") {
                        HStack {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                } else {
                    Text("Nothing recorded yet this session.")
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Diagnostics") {
                    Text(vm.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}

extension RecordingSettingsTab {
    /// Until someone picks, shows what 1.0 did: Apple Intelligence when the Mac has it.
    var namingBinding: Binding<MarkerNaming> {
        Binding(
            get: { vm.markerNaming ?? (MarkerNamer.isAvailable ? .appleIntelligence : .numbered) },
            set: { vm.markerNaming = $0 }
        )
    }

    var namingFooter: String {
        let mode = namingBinding.wrappedValue
        var text = mode.detail
        if mode == .appleIntelligence { text += " Nothing is uploaded." }
        if let reason = MarkerNamer.unavailableReason { text += " Apple Intelligence: \(reason)" }
        return text + " The marker sound is left out of screen and system audio, but a mic can pick it up from speakers; use headphones if that matters."
    }
}

struct SaveFolderRow: View {
    @ObservedObject var storage: RecordingStorage
    let locked: Bool

    var body: some View {
        LabeledContent("Folder") {
            Text(storage.hasUserLocation ? storage.displayPath : "Recaptr's app container (default)")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(storage.hasUserLocation ? .primary : .secondary)
                .help(storage.displayPath)
        }
        HStack {
            Spacer()
            if storage.hasUserLocation {
                Button("Use Default") { storage.resetToDefault() }
                    .disabled(locked)
            }
            Button("Choose Folder…") { storage.pickFolder() }
                .disabled(locked)
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Microphone",
                    detail: "Needed to record audio from mics and capture cards.",
                    granted: vm.audioPermissionStatus == .authorized,
                    onRecheck: { vm.recheckAudioPermission(reason: "settings") },
                    onOpen: { vm.openMicrophonePrivacyPane() }
                )
                PermissionRow(
                    title: "Camera",
                    detail: "Needed for cameras and capture cards.",
                    granted: cameraStatus == .authorized,
                    onRecheck: { cameraStatus = AVCaptureDevice.authorizationStatus(for: .video) },
                    onOpen: { Self.openPrivacyPane("Privacy_Camera") }
                )
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Needed only for Screen and Window sources. After granting, quit and reopen Recaptr.",
                    granted: vm.screenCapturePermissionGranted,
                    onRecheck: { vm.recheckScreenCapturePermission(reason: "settings") },
                    onOpen: { vm.openScreenCapturePrivacyPane() }
                )
            } footer: {
                Text("Recaptr asks for each permission the first time a feature needs it. Notifications are asked for the first time a take ends early while Recaptr is in the background, so you hear about it right away.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let onRecheck: () -> Void
    let onOpen: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.signal)
            } else {
                HStack {
                    Button("Check Again", action: onRecheck)
                    Button("Open Settings", action: onOpen)
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Shortcuts

/// Every action, each with a global key you can set, plus whether other
/// apps can trigger actions through recaptr:// links.
private struct ShortcutsSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Form {
            Section {
                ForEach(RecaptrAction.allCases) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorder(action: action)
                    }
                }
                Button("Restore Defaults") { vm.restoreDefaultHotKeys() }
                    .accessibilityIdentifier("restoreDefaultHotKeys")
            } header: {
                Text("Keys that work from any app")
            } footer: {
                Text("Record and Drop Marker come set to ⌃⌥⌘R and ⌃⌥⌘B. Drop Marker's key only works while recording. Inside Recaptr, the Recording menu has ⌘R and ⌘B too.")
            }

            Section {
                Toggle("Let other apps control Recaptr", isOn: $vm.allowsExternalControl)
                    .accessibilityIdentifier("externalControlToggle")
            } header: {
                Text("Links and Shortcuts")
            } footer: {
                Text("Off by default. When on, Stream Deck, mouse software, scripts and web links can run the actions above with links like recaptr://record/toggle and recaptr://marker, including starting a recording. Links can only run these actions; they can't change settings or touch files. The Shortcuts app works either way.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

/// Click, then type a key combo. Esc cancels, Delete clears.
private struct ShortcutRecorder: View {
    @EnvironmentObject var vm: MainViewModel
    let action: RecaptrAction

    @State private var isRecording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Type a shortcut…" : (vm.hotKeyLabel(for: action) ?? "Not set"))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .help(isRecording ? "Esc to cancel, Delete to clear" : "Click to set a key")
            .accessibilityIdentifier("hotKey-\(action.rawValue)")
            if vm.hotKeyLabel(for: action) != nil, !isRecording {
                Button {
                    problem = vm.setHotKey(nil, for: action)?.message
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear \(action.label) shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        isRecording = true
        // Global keys would grab a combo that's already set (⌃⌥⌘R would
        // start recording) before this field sees it.
        vm.globalHotKeys.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // Delete, Forward Delete
                problem = vm.setHotKey(nil, for: action)?.message
                stop()
            default:
                guard let binding = HotKeyBinding(event: event) else { return event }
                problem = vm.setHotKey(binding, for: action)?.message
                stop()
            }
            return nil
        }
    }

    private func stop() {
        let wasListening = monitor != nil
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if wasListening { vm.refreshGlobalHotKeys() }
    }
}
