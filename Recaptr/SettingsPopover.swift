//
//  SettingsPopover.swift
//  Recaptr
//
//  Phase 6 — gear icon popover that holds everything the floating
//  chrome doesn't surface directly. Lives behind the gear button
//  in the top-right of ContentViewNext.
//
//  Sections, top to bottom:
//    1. Audio       — source picker, gain, enable toggle, VU meter
//    2. Save        — folder selection + reset
//    3. Preview     — start/stop control (in case auto-preview isn't
//                     desired) + Show in Finder for the last recording
//    4. Permissions — mic + screen recording status, with Recheck /
//                     Open Settings actions, only shown when needed
//    5. Status      — current status line, mono-formatted
//
//  All rows reuse the existing internal structs from ContentView.swift
//  (AudioChannelRow, SaveLocationRow, StatusBar, PermissionBanner,
//  ScreenRecordingPermissionBanner), so this popover stays a thin
//  composition layer.
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
    // Phase 6.3.2 — Audio section holds INPUT setup only: mic device
    // picker, gain slider, channel enable, VU readout. Mic gain is a
    // set-and-forget calibration that belongs behind the gear menu.
    //
    // Monitor toggle + monitor volume live on the AudioModule pill
    // on the right edge — they're the dynamic controls that change
    // mid-session (different game = different monitor level), so the
    // pill keeps them one click away.

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
    //
    // Phase 6.2 — folded "Show Last in Finder" into this section.
    // The dedicated Preview section is gone: preview is now an
    // implementation detail (runs automatically when a source is
    // selected, may auto-pause for performance), not a user toggle.

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

    // MARK: Permissions (only when something needs attention)

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

    // MARK: Status (current line of telemetry / probe info / error)

    private var statusSection: some View {
        Section {
            StatusBar(text: vm.status)
        } header: {
            sectionHeader("STATUS")
        }
    }

    // MARK: Section header style

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
