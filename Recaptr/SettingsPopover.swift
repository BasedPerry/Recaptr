//
//  SettingsPopover.swift
//  Recaptr
//
//  Gear-icon popover presented from the top-right of the main
//  window. Holds the controls that aren't surfaced on the floating
//  chrome pills: input audio device + gain, save folder, permission
//  status (only when action is needed), and the current status line.
//
//  Composes existing rows defined in ContentView.swift
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
    // Input setup only: device picker, gain slider, channel enable,
    // VU readout. Monitor toggle + monitor volume live on the right-
    // edge AudioModule pill, since those are the controls a user
    // adjusts mid-session.

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
        } header: {
            sectionHeader("AUDIO")
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
            .foregroundStyle(Color.recaptrAccent)
    }
}

#Preview("Settings Popover") {
    SettingsPopover()
        .environmentObject(MainViewModel())
}
