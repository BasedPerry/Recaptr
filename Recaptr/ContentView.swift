//
//  ContentView.swift
//  Recaptr
//
//  Legacy form-style layout for the main window. The live UI uses
//  `ContentViewNext` (the QuickTime-style floating-chrome layout);
//  this view stays in the project because `SettingsPopover` and other
//  surfaces compose its internal row structs (`AudioChannelRow`,
//  `SaveLocationRow`, `StatusBar`, `PermissionBanner`,
//  `ScreenRecordingPermissionBanner`, `RecordingTelemetryView`,
//  `VUMeterView`, `MonitorRow`). Hoist those into a shared file
//  before deleting this view.
//

import SwiftUI
import AppKit
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        VStack(spacing: 12) {

            SampleBufferPreviewRepresentable(vm: vm)
                .background(Color.black)
                .frame(minWidth: 640, minHeight: 360)
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top)

            VStack(spacing: 10) {
                HStack {
                    // "Source" covers cameras + displays + windows.
                    // `MainViewModel.startPreview()` switches on
                    // `src.kind` to route to the right service.
                    Text("Source:").font(.callout)
                    Picker("Source", selection: $vm.selectedMainSource) {
                        Text("— Select —").tag(VideoSource?.none)
                        ForEach(vm.availableMainSources) { src in
                            Text(src.name).tag(VideoSource?.some(src))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Button("Refresh") {
                        Task { await vm.refreshCatalog() }
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                // User-selected save location row. Shows the current
                // destination plus Change… / Reset actions. Locked
                // while recording so the destination can't change
                // mid-take.
                SaveLocationRow(
                    storage: vm.recordingStorage,
                    locked: vm.isRecording
                )

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

                MonitorRow(
                    enabled: $vm.monitorEnabled,
                    volume: $vm.monitorVolume
                )

                HStack(spacing: 12) {
                    if vm.isPreviewing {
                        Button(role: .destructive) {
                            vm.stopPreview()
                        } label: {
                            Label("Stop Preview", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            Task { await vm.startPreview() }
                        } label: {
                            Label("Start Preview", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.selectedMainSource == nil)
                    }

                    if vm.isPreviewing {
                        if vm.isRecording {
                            Button {
                                Task { await vm.stopRecording() }
                            } label: {
                                Label("Stop Recording", systemImage: "stop.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Button {
                                Task { await vm.startRecording() }
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }

                    if let url = vm.lastRecordedFile, !vm.isRecording {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if vm.isRecording {
                        RecordingTelemetryView(
                            elapsed: vm.recordingElapsed,
                            stats: vm.liveStats,
                            mixerStats: vm.mixerStats
                        )
                    }
                }

                // Permission banner. Shows only when the mic is not
                // authorized; offers Recheck + Open Settings so a
                // stuck "denied" state can be resolved without
                // quitting Recaptr.
                if vm.audioPermissionStatus != .authorized {
                    PermissionBanner(
                        statusEnum: vm.audioPermissionStatus,
                        onRecheck: { vm.recheckAudioPermission(reason: "manual") },
                        onOpenSettings: { vm.openMicrophonePrivacyPane() }
                    )
                }

                // Screen Recording TCC banner — same pattern as the
                // mic banner. Surfaces when Screen Recording isn't
                // authorized and the active source is a screen / window
                // (or nothing is selected yet, so it's discoverable on
                // first launch).
                if !vm.screenCapturePermissionGranted &&
                    (vm.selectedMainSource?.kind != .camera) {
                    ScreenRecordingPermissionBanner(
                        onRecheck: { vm.recheckScreenCapturePermission(reason: "manual") },
                        onOpenSettings: { vm.openScreenCapturePrivacyPane() }
                    )
                }

                // Status on its own wrappable row with the full
                // content available on hover. Probe + permission
                // lines are too long to fit one row reliably.
                StatusBar(text: vm.status)
            }
            .padding(12)
            .padding(.horizontal)
        }
        .padding(.bottom)
        .frame(minWidth: 980, minHeight: 620)
    }
}

// MARK: - Permission banner + status bar

struct PermissionBanner: View {
    let statusEnum: AVAuthorizationStatus
    let onRecheck: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone access: \(label)")
                    .font(.callout)
                Text("Recordings will be silent until access is granted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Recheck", action: onRecheck)
                .buttonStyle(.bordered)
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var label: String {
        switch statusEnum {
        case .notDetermined: return "Not yet requested"
        case .restricted:    return "Restricted (parental controls?)"
        case .denied:        return "Denied"
        case .authorized:    return "Authorized"
        @unknown default:    return "Unknown"
        }
    }
}

/// Save-location row: shows the active save directory (last path
/// component, full path on hover) and lets the user pick a new folder
/// or reset to the sandbox default. Locked while recording so the
/// destination can't change mid-take.
struct SaveLocationRow: View {
    @ObservedObject var storage: RecordingStorage
    let locked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .frame(width: 18)

            Text("Save:")
                .font(.callout)
                .frame(width: 70, alignment: .leading)

            Text(storage.displayLabel)
                .font(.callout.monospaced())
                .foregroundColor(storage.hasUserLocation ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)
                .help(storage.hasUserLocation ? storage.displayPath : "Sandbox container — files written inside Recaptr's app data folder. Click Change… to pick a folder you can actually reach.")

            Button("Change…") {
                storage.pickFolder()
            }
            .buttonStyle(.bordered)
            .disabled(locked)

            if storage.hasUserLocation {
                Button("Reset") {
                    storage.resetToDefault()
                }
                .buttonStyle(.bordered)
                .disabled(locked)
                .help("Revert to the sandbox container default. Existing recordings stay where they are.")
            }

            Spacer()
        }
    }
}

/// Screen Recording TCC banner. Surfaces Open Settings + Recheck so
/// the user can grant Screen Recording, quit + relaunch (the TCC
/// quirk), and re-poll without restarting blindly.
struct ScreenRecordingPermissionBanner: View {
    let onRecheck: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed.badge.record")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording access: not granted")
                    .font(.callout)
                Text("Required to capture displays or windows. Grant in Settings, then quit + relaunch Recaptr.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Recheck", action: onRecheck)
                .buttonStyle(.bordered)
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.5), lineWidth: 0.5)
        )
    }
}

struct StatusBar: View {
    let text: String

    var body: some View {
        // The post-record summary combines recorder counters, mixer
        // counters, per-channel state (with native rate + push / pull
        // / zero-fill counts), and the file-probe result. With line
        // wrapping at typical window width that lands at 5–7 lines;
        // tooltip on hover still has the full text verbatim if it
        // ever clips.
        Text(text)
            .font(.callout.monospaced())
            .foregroundColor(.secondary)
            .lineLimit(8)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .textSelection(.enabled)
    }
}

// MARK: - Audio channel row

struct AudioChannelRow: View {
    let label: String
    let sources: [AudioSource]
    @Binding var deviceID: String?
    @Binding var gain: Double
    @Binding var enabled: Bool
    /// Set while previewing OR recording. Locks the device picker
    /// and enabled toggle — changing those requires the audio engine
    /// to be torn down and rebuilt.
    let deviceLocked: Bool
    /// Set only while recording. The gain slider stays interactive
    /// during preview so the user can dial gain visually against the
    /// live VU meter before committing to a take.
    let gainLocked: Bool
    let stats: AudioInputChannelStats?

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $enabled) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(deviceLocked)
                .help(enabled ? "Channel enabled" : "Channel disabled")

            Text(label)
                .font(.callout)
                .frame(width: 80, alignment: .leading)

            Picker("", selection: $deviceID) {
                Text("None").tag(String?.none)
                ForEach(sources) { src in
                    Text(src.name).tag(String?.some(src.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(deviceLocked || !enabled)
            .frame(maxWidth: 240)

            Slider(value: $gain, in: 0...1.5)
                .disabled(gainLocked || !enabled)
                .frame(maxWidth: 200)

            Text(String(format: "%3d%%", Int(gain * 100)))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            VUMeterView(stats: stats)
                .frame(width: 110, height: 12)

            Spacer()
        }
        .opacity(enabled ? 1.0 : 0.55)
    }
}

/// Live audio monitor controls. The toggle routes mixer output to
/// the system default output device; the slider drives
/// `monitorEngine.mainMixerNode.outputVolume`. Both stay interactive
/// during preview AND recording — flipping the monitor doesn't
/// affect what gets muxed into the file.
private struct MonitorRow: View {
    @Binding var enabled: Bool
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $enabled) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
                .help(enabled ? "Live monitor ON — game audio plays through system output" : "Live monitor OFF")

            Image(systemName: enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundColor(enabled ? .secondary : .secondary.opacity(0.5))
                .frame(width: 18)

            Text("Monitor")
                .font(.callout)
                .frame(width: 70, alignment: .leading)

            Slider(value: $volume, in: 0...1.5)
                .disabled(!enabled)
                .frame(maxWidth: 200)

            Text(String(format: "%3d%%", Int(volume * 100)))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            Spacer()
        }
        .opacity(enabled ? 1.0 : 0.55)
    }
}

/// VU meter rendered from `AudioInputChannelStats`. Maps the
/// −60 dBFS … 0 dBFS range to a 0…1 fill in green → yellow → red
/// zones. Renders empty when `stats` is nil or the channel isn't
/// running.
private struct VUMeterView: View {
    let stats: AudioInputChannelStats?

    private static let floorDb: Float = -60
    private static let topDb: Float = 0

    private var rmsFraction: CGFloat {
        guard let s = stats, s.running else { return 0 }
        return CGFloat(VUMeterView.normalize(s.rmsDbfs))
    }

    private var peakFraction: CGFloat {
        guard let s = stats, s.running else { return 0 }
        return CGFloat(VUMeterView.normalize(s.peakDbfs))
    }

    private static func normalize(_ db: Float) -> Float {
        let x = (db - floorDb) / (topDb - floorDb)
        if x < 0 { return 0 }
        if x > 1 { return 1 }
        return x
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .leading) {
                // background
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                // RMS fill, color-zoned
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(meterGradient)
                    .frame(width: w * rmsFraction)
                // peak tick
                if peakFraction > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1.5, height: h)
                        .offset(x: max(0, w * peakFraction - 0.75))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
            )
        }
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green,  location: 0.0),
                .init(color: .green,  location: 0.66),  // up to ~ -20 dBFS
                .init(color: .yellow, location: 0.83),  // up to ~ -10 dBFS
                .init(color: .red,    location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Recording telemetry pill

/// Compact live readout shown only while a recording is running.
/// Format: "● 00:34  v=2040 a=1632 drop=0/0  mix=24576f zf=0/0"
struct RecordingTelemetryView: View {
    let elapsed: TimeInterval
    let stats: RecorderStats
    let mixerStats: AudioMixerStats

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(stats.sessionAnchored ? 1.0 : 0.3)
            Text(formatElapsed(elapsed))
                .font(.callout.monospaced())
                .foregroundColor(.primary)
            Text("v=\(stats.videoAccepted) a=\(stats.audioAccepted) drop=\(stats.audioDroppedPreAnchor)/\(stats.audioDroppedNotReady)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            if mixerStats.running {
                Text("mix=\(mixerStats.mixedFramesEmitted)f zf=\(zeroFillCounters(mixerStats))")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func zeroFillCounters(_ m: AudioMixerStats) -> String {
        m.channels.map { String($0.zeroFillEvents) }.joined(separator: "/")
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    ContentView()
        .environmentObject(MainViewModel())
}
