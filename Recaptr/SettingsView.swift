//
//  SettingsView.swift
//  Recaptr
//
//  The macOS Settings window (Recaptr > Settings…, ⌘, or the gear
//  button): app-wide settings only. Per-method tuning (sources,
//  capture resolution, audio devices and gain, instant replay) lives
//  in the source sidebar; monitor volume lives on the audio card.
//
//  Tabs:
//    Recording    encoding preset, save folder, last recording
//    Permissions  microphone, camera, screen recording
//

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        TabView {
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

// MARK: - Recording

private struct RecordingSettingsTab: View {
    @EnvironmentObject var vm: MainViewModel
    @State private var renaming = false

    var body: some View {
        Form {
            Section {
                Picker("Encoding", selection: $vm.videoQuality) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .disabled(vm.isRecording)
            } header: {
                Text("Video")
            } footer: {
                Text(encodingFooter)
            }

            Section("Save location") {
                SaveFolderRow(storage: vm.recordingStorage, locked: vm.isRecording)
            }

            Section {
                Toggle("Name markers and episodes with Apple Intelligence", isOn: $vm.aiNamingEnabled)
                    .disabled(!MarkerNamer.isAvailable)
            } header: {
                Text("Naming")
            } footer: {
                Text(MarkerNamer.unavailableReason
                     ?? "After you stop, each marker gets a short name from its frame and what you said around it, and a blank episode gets a title. Runs on your Mac; nothing is uploaded.")
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
                            if vm.lastTake != nil {
                                Button("Rename…") { renaming = true }
                                    .disabled(vm.isRecording)
                                    .accessibilityIdentifier("renameTakeButton")
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
        .sheet(isPresented: $renaming) {
            if let take = vm.lastTake {
                RenameTakeSheet(take: take)
                    .environmentObject(vm)
            }
        }
    }
}

/// Rename the last take's episode and its markers after the fact
/// (Apple Intelligence names will sometimes miss).
private struct RenameTakeSheet: View {
    @EnvironmentObject var vm: MainViewModel
    @Environment(\.dismiss) private var dismiss
    let take: MainViewModel.LastTake

    @State private var episode = ""
    @State private var titles: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(take.series.isEmpty ? "Name" : "Episode", text: $episode)
                        .accessibilityIdentifier("renameEpisodeField")
                } header: {
                    Text(take.series.isEmpty ? "Recording" : take.series)
                } footer: {
                    Text(previewName)
                }
                if !titles.isEmpty {
                    Section("Markers") {
                        ForEach(titles.indices, id: \.self) { index in
                            TextField(timecode(take.markers[index].seconds), text: $titles[index])
                                .accessibilityIdentifier("renameMarker\(index)")
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    Task {
                        do {
                            try await vm.renameLastTake(episode: episode, markerTitles: titles)
                            dismiss()
                        } catch {
                            self.error = "Couldn't rename: \(error.localizedDescription)"
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(SessionNaming.sanitize(episode).isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .onAppear {
            episode = take.episode
            titles = take.markers.map(\.title)
        }
    }

    private var previewName: String {
        let clean = SessionNaming.sanitize(episode)
        let base = take.series.isEmpty ? clean : SessionNaming.baseName(series: take.series, episode: clean)
        return "Saves as \(base).mov"
    }

    private func timecode(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

extension RecordingSettingsTab {
    /// Bitrate and size per hour at the current capture size.
    var encodingFooter: String {
        var text = "HEVC keeps more detail than H.264 at the same size and works in Final Cut. Use Compatible only for tools that can't open HEVC."
        if let size = vm.activeCaptureSize {
            let mbps = vm.videoQuality.bitrate(width: size.width, height: size.height) / 1_000_000
            let gb = Int(vm.videoQuality.gigabytesPerHour(width: size.width, height: size.height).rounded())
            text = "At \(size.width)×\(size.height): \(mbps) Mbps, about \(gb) GB per hour. " + text
        }
        return text
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
