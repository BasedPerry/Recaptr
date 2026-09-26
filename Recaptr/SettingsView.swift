//
//  SettingsView.swift
//  Recaptr
//
//  The macOS Settings window (Recaptr > Settings…, ⌘, or the gear
//  button). Replaces the old gear popover, which crammed each audio
//  channel into one row too wide for it and locked the device pickers
//  whenever preview was running (which is always).
//
//  Tabs:
//    Audio        source audio, commentary mic, monitor
//    Video        encoding, low-light noise reduction, instant replay
//    Recording    save folder, last recording, diagnostics
//    Permissions  microphone, camera, screen recording
//
//  Audio devices apply live while previewing (MainViewModel
//  .applyAudioSelectionChange) and lock only while recording.
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        TabView {
            Tab("Audio", systemImage: "waveform") {
                AudioSettingsTab()
            }
            Tab("Video", systemImage: "video") {
                VideoSettingsTab()
            }
            Tab("Recording", systemImage: "record.circle") {
                RecordingSettingsTab()
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsTab()
            }
        }
        .environmentObject(vm)
        .frame(width: 540)
    }
}

// MARK: - Audio

private struct AudioSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Form {
            Section {
                devicePicker(selection: $vm.ch1DeviceID, id: "sourceDevicePicker")
                GainRow(gain: $vm.ch1Gain, locked: vm.isRecording)
                LevelRow(channel: 0)
            } header: {
                Text("Source audio")
            } footer: {
                Text("Picked automatically to match the camera or capture card. Screen and Window sources record system audio instead.")
            }

            Section {
                devicePicker(selection: $vm.ch2DeviceID, id: "micDevicePicker")
                GainRow(gain: $vm.ch2Gain, locked: vm.isRecording)
                LevelRow(channel: 1)
            } header: {
                Text("Commentary mic")
            } footer: {
                Text("Mixed on top of the source audio. With two sources, each also gets its own track in the file so you can rebalance later.")
            }

            Section {
                Toggle("Listen while capturing", isOn: $vm.monitorEnabled)
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $vm.monitorVolume, in: 0...1.5)
                            .disabled(!vm.monitorEnabled)
                        Text("\(Int(vm.monitorVolume * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Monitor")
            } footer: {
                Text("Plays the source audio through your current output. Toggle with ⌘K. Your mic is never monitored.")
            }

            if vm.isRecording {
                Section {
                    Label("Devices are locked while recording.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 660)
    }

    private func devicePicker(selection: Binding<String?>, id: String) -> some View {
        Picker("Device", selection: selection) {
            Text("None").tag(String?.none)
            ForEach(vm.availableAudioSources) { src in
                Text(src.name).tag(String?.some(src.id))
            }
        }
        .disabled(vm.isRecording)
        .accessibilityIdentifier(id)
    }
}

private struct GainRow: View {
    @Binding var gain: Double
    let locked: Bool

    var body: some View {
        LabeledContent("Gain") {
            HStack {
                Slider(value: $gain, in: 0...1.5)
                    .disabled(locked)
                Text("\(Int(gain * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Live level meter for one mixer channel, redrawn at 30 fps.
private struct LevelRow: View {
    @EnvironmentObject var vm: MainViewModel
    let channel: Int

    var body: some View {
        LabeledContent("Level") {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                LevelMeter(levels: vm.channelLevels(channel))
            }
            .frame(height: 8)
        }
    }
}

private struct LevelMeter: View {
    let levels: (rms: Float, peak: Float)?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(contrast == .increased ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                if let levels {
                    Capsule()
                        .fill(LinearGradient(
                            stops: [
                                .init(color: .signal, location: 0.0),
                                .init(color: .signal, location: 0.6),
                                .init(color: .warningAmber, location: 0.85),
                                .init(color: .red, location: 1.0),
                            ],
                            startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: w * fraction(levels.rms))
                        }
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: max(0, w * fraction(levels.peak) - 1))
                        .opacity(levels.peak > -100 ? 0.8 : 0)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(levels.map { String(format: "%.0f dB peak", $0.peak) } ?? "No signal")
    }

    /// −60…0 dBFS → 0…1.
    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}

// MARK: - Video

private struct VideoSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Form {
            Section {
                Picker("Encoding", selection: $vm.videoQuality) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .disabled(vm.isRecording)
            } footer: {
                Text("Constant quality keeps image quality steady and lets file size vary: smaller for static screens, larger for busy gameplay (up to 40 Mbps).")
            }

            Section {
                Toggle("Low-light noise reduction", isOn: $vm.lowLightNoiseReduction)
                    .disabled(vm.isRecording || !vm.lowLightNoiseReductionSupported)
                    .onChange(of: vm.lowLightNoiseReduction) { _, _ in
                        // Applied when the camera session is built.
                        if vm.isPreviewing, !vm.isRecording,
                           vm.selectedMainSource?.kind == .camera {
                            Task { await vm.startPreview() }
                        }
                    }
            } footer: {
                Text(vm.lowLightNoiseReductionSupported
                     ? "Cleans up grain in dim webcam footage. It changes the image, so it's off by default."
                     : "Not supported by the current source. Available with webcams and Continuity Camera, not capture cards.")
            }

            Section {
                Toggle("Instant replay", isOn: $vm.instantReplay)
                    .disabled(vm.isRecording)
                    .onChange(of: vm.instantReplay) { _, _ in
                        // The buffer is attached when the stream starts.
                        if vm.isPreviewing, !vm.isRecording,
                           vm.selectedMainSource?.kind != .camera {
                            Task { await vm.startPreview() }
                        }
                    }
            } footer: {
                Text("Keeps the last 15 seconds of a Screen or Window source in memory. Press ⇧⌘R to save it as a clip, recording or not.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}

// MARK: - Recording

private struct RecordingSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Form {
            Section("Save location") {
                SaveFolderRow(storage: vm.recordingStorage, locked: vm.isRecording)
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
        .frame(height: 360)
    }
}

private struct SaveFolderRow: View {
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
                Text("Recaptr asks for each permission the first time a feature needs it.")
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
