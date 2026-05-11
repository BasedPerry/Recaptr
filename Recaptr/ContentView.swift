//
//  ContentView.swift
//  Recaptr
//
//  Phase 2: preview + camera picker + Start/Stop.
//  Phase 3: Record + Stop Recording + Show in Finder.
//  Phase 4 (2026-05-09): audio source picker (None or any AudioSource).
//  Phase 4 hardening (2026-05-09 evening):
//    - Live elapsed-time readout while recording (mm:ss / h:mm:ss).
//    - Live "v / a / drop" buffer counters from MainViewModel.liveStats
//      so a long-session test surfaces immediately whether audio is
//      actually landing in the file.
//  Phase 4.5 (2026-05-09 evening, follow-on):
//    - Two audio channel rows. Each has a device picker (None or any
//      AudioSource), a gain slider (0–100 %), and an enabled toggle.
//    - Both rows disabled while recording (per locked decision #2:
//      pre-record-only volume).
//    - Telemetry pill expanded with per-channel zero-fill counters
//      so a long recording surfaces drift / starvation immediately.
//  Phase 4.6 (2026-05-09 evening, diagnostics polish):
//    - Per-channel VU meter (RMS dBFS, smoothed) next to the gain
//      slider — visible during preview AND recording. If meters
//      show signal but file plays silent, problem is downstream.
//      If meters are dead, problem is upstream (TCC, device routing).
//    - Status line shows the post-record file-probe result so
//      "no audio in the file" is impossible to miss.
//  Phase 4.6.1 (2026-05-09 night, hotfix):
//    - Status text moved to its own row, wraps to 3 lines, and has
//      a help() tooltip with the full content on hover. The old
//      single-line truncated layout was useless for debugging.
//    - "Recheck Mic" button + "Open Settings" button surface
//      whenever audioPermissionStatus isn't .authorized, so a
//      stuck "denied" state can be re-resolved without quitting.
//  Phase 4.7 (2026-05-09 night, monitor function):
//    - AudioChannelRow gained two lock parameters:
//      `deviceLocked` (preview OR recording) — disables device
//      picker + enabled toggle (changing those requires Stop
//      Preview / Start Preview to rebind the engine).
//      `gainLocked` (recording only) — slider stays interactive
//      during preview so Brandon can dial gain visually with the
//      VU meter live.
//  Phase 4.9 (2026-05-09 night, closes out 4.x):
//    - Removed Channel 2 row. Single audio source.
//    - New MonitorRow: toggle + output volume slider for live
//      foldback to system speakers. Toggle and slider are
//      interactive at all times (no lock) — Brandon can flip the
//      monitor on/off and adjust output volume during recording
//      without affecting the recording itself.
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
                    Text("Camera:").font(.callout)
                    Picker("Camera", selection: $vm.selectedMainSource) {
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

                // Phase 4.6.1 — permission banner. Only shows when
                // mic is not authorized; offers two actions to
                // unstick the situation without quitting.
                if vm.audioPermissionStatus != .authorized {
                    PermissionBanner(
                        statusEnum: vm.audioPermissionStatus,
                        onRecheck: { vm.recheckAudioPermission(reason: "manual") },
                        onOpenSettings: { vm.openMicrophonePrivacyPane() }
                    )
                }

                // Phase 4.6.1 — status on its own row, wrappable,
                // with the full content available on hover. The
                // probe + permission lines are too long for one
                // row, and the old single-line truncation made
                // them useless for debugging.
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

private struct PermissionBanner: View {
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

private struct StatusBar: View {
    let text: String

    var body: some View {
        // Phase 4.6.4 — line limit bumped from 3 to 8 because the
        // post-record summary now combines recorder counters,
        // mixer counters, per-channel state (with native rate +
        // push/pull/zf counts), and the file-probe result. With
        // line wrapping at typical window width this lands at
        // 5–7 lines. Tooltip on hover still has the full text
        // verbatim if anything still gets clipped.
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

private struct AudioChannelRow: View {
    let label: String
    let sources: [AudioSource]
    @Binding var deviceID: String?
    @Binding var gain: Double
    @Binding var enabled: Bool
    /// Phase 4.7 — preview OR recording. Locks device picker +
    /// enabled toggle (changing those requires the audio engine to
    /// be torn down and rebuilt).
    let deviceLocked: Bool
    /// Phase 4.7 — recording only. Slider stays interactive during
    /// preview so Brandon can dial gain visually against the live
    /// VU meter.
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

/// Phase 4.9 — live audio monitor controls. Toggle routes mixer
/// output to the system default output device; volume slider drives
/// monitorEngine.mainMixerNode.outputVolume. Both stay interactive
/// during preview AND recording — flipping the monitor doesn't
/// affect what gets muxed into the file. Intentionally minimal
/// styling for now (ugly is fine, we're styling later).
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

/// Phase 4.6 — VU meter rendered from AudioInputChannelStats.
/// Maps -60 dBFS … 0 dBFS to 0…1 fill. Green → yellow → red zones.
/// If stats is nil or the channel isn't running, renders empty.
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
private struct RecordingTelemetryView: View {
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
