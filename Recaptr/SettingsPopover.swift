//
//  SettingsPopover.swift
//  Recaptr
//
//  Gear-icon popover presented from the top-right of the main
//  window. Holds the controls that aren't surfaced on the floating
//  chrome pills: input audio device + gain, save folder, permission
//  status (only when action is needed), and the current status line.
//
//  Composes existing rows defined in SettingsRows.swift
//  (AudioChannelRow, SaveLocationRow, StatusBar, PermissionBanner,
//  ScreenRecordingPermissionBanner) so this file stays a thin
//  presentation layer.
//

import SwiftUI
import AVFoundation

struct SettingsPopover: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Form {
            audioSection
            videoSection
            saveSection
            permissionsSection
            statusSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(maxHeight: 560)
    }

    // MARK: Audio
    //
    // Input setup only: source audio and commentary mic, each with a
    // device picker, gain slider, channel enable, and VU readout.
    // Monitor toggle + monitor volume live on the right-edge
    // AudioModule pill, since those are the controls a user adjusts
    // mid-session.

    private var audioSection: some View {
        Section {
            AudioChannelRow(
                label: "Audio",
                sources: vm.availableAudioSources,
                deviceID: $vm.ch1DeviceID,
                gain: $vm.ch1Gain,
                enabled: $vm.ch1Enabled,
                deviceLocked: vm.isPreviewing || vm.isRecording,
                gainLocked: vm.isRecording,
                stats: vm.mixerStats.channels.indices.contains(0) ? vm.mixerStats.channels[0] : nil
            )
            // Commentary mic, mixed on top of the source audio. Pick
            // "None" to turn it off.
            AudioChannelRow(
                label: "Mic",
                sources: vm.availableAudioSources,
                deviceID: $vm.ch2DeviceID,
                gain: $vm.ch2Gain,
                enabled: $vm.ch2Enabled,
                deviceLocked: vm.isPreviewing || vm.isRecording,
                gainLocked: vm.isRecording,
                stats: vm.mixerStats.channels.indices.contains(1) ? vm.mixerStats.channels[1] : nil
            )
        } header: {
            sectionHeader("AUDIO")
        }
    }

    // MARK: Video

    private var videoSection: some View {
        Section {
            Picker("Encoding", selection: $vm.videoQuality) {
                ForEach(VideoQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .disabled(vm.isRecording)
            .help("Constant quality keeps image quality steady and lets file size vary: smaller for static screens, larger for busy gameplay.")

            // Only offered when the current camera supports it.
            if vm.lowLightNoiseReductionSupported {
                Toggle("Low-light noise reduction", isOn: $vm.lowLightNoiseReduction)
                    .disabled(vm.isRecording)
                    .help("Cleans up grain in dim webcam footage. Changes the image, so it's off by default. Applies to the recording.")
                    .onChange(of: vm.lowLightNoiseReduction) { _, _ in
                        // Applied when the camera session is built.
                        if vm.isPreviewing, !vm.isRecording {
                            Task { await vm.startPreview() }
                        }
                    }
            }
        } header: {
            sectionHeader("VIDEO")
        }
    }

    // MARK: Save Location

    private var saveSection: some View {
        Section {
            SaveLocationRow(
                storage: vm.recordingStorage,
                locked: vm.isRecording
            )

            if let url = vm.lastRecordedFile, !vm.isRecording {
                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show Last in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        } header: {
            sectionHeader("SAVE LOCATION")
        }
    }

    // MARK: Permissions (rendered only when something needs action)

    private var permissionsSection: some View {
        let micNeedsAction = vm.audioPermissionStatus != .authorized
        let screenNeedsAction =
            !vm.screenCapturePermissionGranted &&
            (vm.selectedMainSource?.kind != .camera)

        return Group {
            if micNeedsAction || screenNeedsAction {
                Section {
                    if micNeedsAction {
                        PermissionBanner(
                            statusEnum: vm.audioPermissionStatus,
                            onRecheck: { vm.recheckAudioPermission(reason: "settings popover") },
                            onOpenSettings: { vm.openMicrophonePrivacyPane() }
                        )
                    }
                    if screenNeedsAction {
                        ScreenRecordingPermissionBanner(
                            onRecheck: { vm.recheckScreenCapturePermission(reason: "settings popover") },
                            onOpenSettings: { vm.openScreenCapturePrivacyPane() }
                        )
                    }
                } header: {
                    sectionHeader("PERMISSIONS")
                }
            }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            StatusBar(text: vm.status)
        } header: {
            sectionHeader("STATUS")
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
}

#Preview("Settings Popover") {
    SettingsPopover()
        .environmentObject(MainViewModel())
}
