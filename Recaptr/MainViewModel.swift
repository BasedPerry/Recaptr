//
//  MainViewModel.swift
//  Recaptr
//
//  Phase 2: camera-source preview, owns DeviceCatalog + preview layer.
//  Phase 3: Recorder + recording state.
//  Phase 4: single audio source via AVCaptureSession + appendAudio.
//  Phase 4 hardening (2026-05-09 evening):
//    - recordingStartedAt + recordingElapsed for the elapsed timer.
//    - liveStats published from a 1s recorderStatsTimer.
//    - On writer.status = .failed mid-recording, stop cleanly + surface.
//  Phase 4.5 (2026-05-09 evening, follow-on):
//    - Replaced single selectedAudioSource with a 2-channel
//      AudioMixer (per locked decision #2: per-source pre-record
//      volume, single mixed AAC track).
//    - Channel 1 / Channel 2 each get their own device, gain (0..1),
//      enabled toggle. ContentView surfaces them as sliders + pickers.
//    - mixerStats published alongside liveStats so the UI can show
//      per-channel pushed/pulled/zero-fill counters during a long
//      recording.
//  Phase 4.6 (2026-05-09 evening, diagnostics polish):
//    - Explicit AVCaptureDevice.requestAccess(for: .audio) at init
//      so the macOS TCC mic prompt fires reliably. Relying on
//      AVAudioEngine to trigger TCC at a different code-path was
//      the most likely cause of "build runs, file is silent."
//      audioPermissionStatus is published for UI surfacing.
//    - Post-record AVAsset probe of the saved .mov: opens the file,
//      enumerates audio tracks, reports duration + format. Result
//      surfaces in `lastFileProbeSummary` and the status line so
//      Brandon sees immediately whether audio actually landed.
//  Phase 4.6.1 (2026-05-09 night, hotfix):
//    - Status text now wraps + has a help() tooltip on hover (was
//      single-line truncated, useless for debugging long messages).
//    - Permission re-checks on every NSApplication.didBecomeActive
//      (so toggling System Settings → Privacy → Microphone updates
//      the app within a second of returning to it).
//    - recheckAudioPermission() exposed as a method the UI can call
//      from a "Recheck Mic" button.
//    - openMicrophonePrivacyPane() opens System Settings directly
//      to the Microphone privacy panel.
//    - Init logs bundle ID + initial permission state to the Xcode
//      console so we can verify `tccutil reset Microphone <bundle>`
//      is targeting the right identifier.
//  Phase 4.7 (2026-05-09 night, monitor function):
//    - AudioMixer lifecycle moved from recording-only to preview.
//      Mixer starts at Start Preview, stops at Stop Preview, and
//      keeps running through Record→Stop. Result: VU meters dance
//      as soon as preview is up — Brandon can see signal and tune
//      gains before committing to a take.
//    - Gain sliders push live to channels via Combine
//      ($ch1Gain.sink → channel.gain). Device picker + enabled
//      toggle stay locked during preview (changing those requires
//      Stop Preview / Start Preview to rebind the audio engine).
//    - Stats timer runs throughout preview, not just recording.
//      mixerStats updates during preview so VU meters animate.
//      recordingElapsed only ticks during actual recording.
//  Phase 4.9 (2026-05-09 night, closes out 4.x):
//    - REMOVED Channel 2 entirely. Single-source UX: one audio
//      input picker, one gain slider, one VU meter. The Phase 4.7.4
//      multi-source graceful-degradation path is preserved in
//      AudioMixer (still N-channel internally) so Phase 4.8
//      aggregate-device work can land later without rewriting.
//    - ADDED live audio monitor: a separate output-only AVAudioEngine
//      in AudioInputChannel plays each post-gain buffer to the system
//      default output device. Toggle ON/OFF + 0–150 % output volume
//      slider. Output-only engines avoid the multi-input HAL conflict
//      that broke two-channel capture.
//

import Foundation
import Combine
import SwiftUI
import AppKit
import AVFoundation
import CoreMedia

@MainActor
final class MainViewModel: ObservableObject {

    @Published var catalog = DeviceCatalog()
    @Published var selectedMainSource: VideoSource?

    // Phase 4.9 — single-source channel state. (ch2* properties
    // removed. AudioMixer is still N-channel internally so Phase 4.8
    // aggregate-device support can land later without UI rework.)
    @Published var ch1DeviceID: String?
    @Published var ch1Gain: Double = 1.0
    @Published var ch1Enabled: Bool = true

    // Phase 4.9 — live audio monitor (foldback to system output).
    @Published var monitorEnabled: Bool = false
    @Published var monitorVolume: Double = 1.0  // 0…1.5

    @Published var isPreviewing = false
    @Published var isRecording = false
    @Published var status: String = "Idle"
    @Published var lastRecordedFile: URL?

    // Phase 4 hardening — telemetry surfaced to ContentView.
    @Published var recordingElapsed: TimeInterval = 0
    @Published var liveStats: RecorderStats = RecorderStats()
    @Published var mixerStats: AudioMixerStats = AudioMixerStats()

    // Phase 4.6 — TCC + file probe.
    @Published var audioPermissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var lastFileProbeSummary: String?

    // Phase 4.6.4 — preserve the recorder/mixer counters past the
    // probe completion. Without this, the probe's status update
    // overwrites the only place we surfaced them, and we lose the
    // post-recording diagnostic state.
    @Published var lastRecordingSummary: String?

    // Phase 4.6.1 — observers retained so they can be removed.
    private var didBecomeActiveObserver: NSObjectProtocol?

    // Phase 4.7 — Combine subscriptions for live gain.
    private var cancellables = Set<AnyCancellable>()

    let previewSinkLayer = SampleBufferPreviewLayer(frame: .zero)

    private var cameraService: CameraCaptureService?
    private let recorder = Recorder()
    private let audioMixer: AudioMixer
    private var activeDims: CMVideoDimensions = .init(width: 0, height: 0)
    private var hasAudio = false  // Snapshot at startRecording — locked until stopRecording

    private var recordingStartedAt: Date?
    private var recorderStatsTimer: Timer?

    init() {
        // Phase 4.9 — single-channel mixer. AudioMixer's N-channel
        // architecture is preserved internally so Phase 4.8 (aggregate
        // device) can introduce additional channels later without UI
        // rework.
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let channel = AudioInputChannel(label: "Audio", outputFormat: outputFormat)
        self.audioMixer = AudioMixer(channels: [channel])

        // Wire mixer → recorder.
        audioMixer.onMixedSampleBuffer = { [weak self] sb in
            self?.recorder.appendAudio(sb)
        }

        // Phase 4.7 — push live gain changes into the mixer.
        // Gain is read on every tap callback, so updating the
        // channel.gain Float is sufficient — no engine restart.
        $ch1Gain
            .sink { [weak self] value in
                self?.audioMixer.channel(at: 0)?.gain = Float(value)
            }
            .store(in: &cancellables)

        // Phase 4.9 — monitor toggle + volume wired live.
        $monitorEnabled
            .sink { [weak self] enabled in
                self?.audioMixer.channel(at: 0)?.setMonitor(enabled: enabled)
            }
            .store(in: &cancellables)
        $monitorVolume
            .sink { [weak self] value in
                self?.audioMixer.channel(at: 0)?.monitorVolume = Float(value)
            }
            .store(in: &cancellables)

        // Phase 4.6.1 — log identity at startup so we can verify
        // tccutil reset is targeting the right bundle.
        let bundleID = Bundle.main.bundleIdentifier ?? "<unknown>"
        let initialMic = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Recaptr launched — bundle=\(bundleID), mic permission=\(Self.permissionLabel(initialMic))")

        // Phase 4.6.1 — recheck whenever the app comes back to
        // front (user toggles Privacy & Security → Microphone, then
        // returns; we'll see the new state within a second).
        // Phase 4.6.2 — guard-let inside the closure so the Task
        // captures an immutable `let`, not the weak `var` optional
        // (Swift 6 strict concurrency).
        let center = NotificationCenter.default
        didBecomeActiveObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.recheckAudioPermission(reason: "app activated")
            }
        }

        Task { await self.refreshCatalog() }
        Task { await self.requestAudioPermissionIfNeeded() }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    /// Phase 4.6 — explicitly fire the macOS mic TCC prompt at app
    /// startup. This is the single most-common cause of "file is
    /// silent": the user denied (or never saw) the mic permission
    /// prompt, AVAudioEngine starts, the input bus has zero rate
    /// or the tap delivers silence, and nothing else surfaces it.
    /// Calling AVCaptureDevice.requestAccess() routes through the
    /// same TCC entitlement (NSMicrophoneUsageDescription).
    func requestAudioPermissionIfNeeded() async {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        audioPermissionStatus = current
        print("requestAudioPermissionIfNeeded: status=\(Self.permissionLabel(current))")
        if current == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            let resolved = AVCaptureDevice.authorizationStatus(for: .audio)
            audioPermissionStatus = resolved
            print("requestAudioPermissionIfNeeded: requestAccess returned granted=\(granted), resolved status=\(Self.permissionLabel(resolved))")
            if !granted {
                status = "Microphone permission denied — recordings will be silent. Open System Settings → Privacy & Security → Microphone to enable."
            }
        } else if current == .denied || current == .restricted {
            status = "Microphone permission denied — recordings will be silent. Open System Settings → Privacy & Security → Microphone to enable."
        }
    }

    /// Phase 4.6.1 — re-poll the OS for the current mic permission
    /// state and update both the published flag and the status line.
    /// Called from the NSApplication.didBecomeActive observer and
    /// from a UI button. Doesn't fire a TCC prompt — for that, call
    /// requestAudioPermissionIfNeeded() (which only prompts on
    /// .notDetermined).
    func recheckAudioPermission(reason: String) {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        let was = audioPermissionStatus
        audioPermissionStatus = current
        if current != was {
            print("recheckAudioPermission(\(reason)): \(Self.permissionLabel(was)) → \(Self.permissionLabel(current))")
        }

        switch current {
        case .authorized:
            // Clear any leftover "denied" status — only if the
            // current status is still the denied message (don't
            // clobber a probe result or a recording status).
            if status.hasPrefix("Microphone permission denied") {
                status = "Idle"
            }
        case .denied, .restricted:
            status = "Microphone permission denied — recordings will be silent. Open System Settings → Privacy & Security → Microphone to enable."
        case .notDetermined:
            // Fire the prompt asynchronously.
            Task { await self.requestAudioPermissionIfNeeded() }
        @unknown default:
            break
        }
    }

    /// Phase 4.6.1 — open System Settings directly to the Microphone
    /// privacy panel so the user doesn't have to navigate.
    func openMicrophonePrivacyPane() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        // Last-ditch fallback: open the privacy pane root.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func permissionLabel(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    func refreshCatalog() async {
        await catalog.refresh()
    }

    var availableMainSources: [VideoSource] {
        catalog.videoSources.filter { $0.kind == .camera }
    }

    var availableAudioSources: [AudioSource] {
        catalog.audioSources
    }

    /// Phase 4.9 — single-channel: armed when device selected + toggle on.
    private var anyChannelArmed: Bool {
        ch1Enabled && ch1DeviceID != nil
    }

    // MARK: - Preview

    func startPreview() async {
        stopPreview()

        // Phase 4.6.1 — recheck mic permission right before any
        // capture work. If the user just granted access in System
        // Settings, this clears the stale "denied" status.
        recheckAudioPermission(reason: "startPreview")

        guard let src = selectedMainSource else {
            status = "Select a camera source"
            return
        }
        guard src.kind == .camera, let cameraID = src.cameraUniqueID else {
            status = "Selected source is not a camera (Phase 5+)"
            return
        }

        let svc = CameraCaptureService()
        svc.onRecordBuffer = { [weak self] sb in self?.recorder.appendVideo(sb) }

        do {
            let dims = try await svc.start(
                cameraUniqueID: cameraID,
                previewSink: previewSinkLayer
            )
            cameraService = svc
            activeDims = dims
            isPreviewing = true

            // Phase 4.7 — start the audio mixer so VU meters work
            // pre-record. Mixer keeps running through Record / Stop;
            // it only stops when preview ends. If audio start fails
            // (e.g., a channel's TCC denied for one device), continue
            // with video-only preview — recording still works, just
            // without audio monitoring or capture.
            configureMixerFromUIState()
            var monitorLabel = ""
            if audioMixer.hasAnyEnabledChannel {
                do {
                    try audioMixer.start()
                    monitorLabel = " · audio monitor ON"
                    startStatsTimer()
                } catch {
                    monitorLabel = " · audio monitor failed: \(error.localizedDescription)"
                }
            } else {
                monitorLabel = " · no audio channels armed"
            }

            status = "Previewing — \(src.name) (\(dims.width)×\(dims.height))\(monitorLabel)"
        } catch {
            status = "Camera error: \(error.localizedDescription)"
        }
    }

    func stopPreview() {
        if isRecording {
            Task { await self.stopRecording() }
        }
        // Phase 4.7 — tear down the mixer + stats timer when preview
        // ends. The mixer's lifecycle is now scoped to preview, not
        // recording.
        if audioMixer.running { audioMixer.stop() }
        stopStatsTimer()
        // Reset transient mixer stats so VU meters go dark when
        // preview is off (otherwise the last-known values linger).
        mixerStats = AudioMixerStats()

        cameraService?.stop()
        cameraService = nil
        previewSinkLayer.flush()
        isPreviewing = false
        if status.hasPrefix("Previewing") { status = "Idle" }
    }

    // MARK: - Recording

    func startRecording() async {
        guard isPreviewing else { status = "Start preview first"; return }
        guard activeDims.width > 0, activeDims.height > 0 else {
            status = "No active video dimensions"
            return
        }
        guard !isRecording else { return }

        // Phase 4.7 — mixer is already running from preview. We just
        // need to determine whether audio will be muxed (true if any
        // channel is enabled and actually running, false otherwise).
        hasAudio = audioMixer.running && audioMixer.hasAnyEnabledChannel

        do {
            let url = try await recorder.start(
                width: activeDims.width,
                height: activeDims.height,
                withAudio: hasAudio
            )
            isRecording = true
            recordingStartedAt = Date()
            recordingElapsed = 0
            // Don't reset mixerStats — preview's VU/state continuity
            // is more useful than a clean slate at the moment record
            // starts.
            liveStats = RecorderStats()
            lastRecordedFile = nil
            let audioLabel = hasAudio ? " + audio (mixer)" : " (video only — no audio armed)"
            status = "Recording → \(url.lastPathComponent)\(audioLabel)"
            // Stats timer is already running from preview — no need
            // to restart.
        } catch {
            status = "Recorder error: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        // Phase 4.7 — mixer + timer keep running for ongoing
        // preview/monitoring. Only the recorder stops here.
        let url = await recorder.stop()
        isRecording = false
        recordingStartedAt = nil
        lastRecordedFile = url

        // Take one final stats snapshot AFTER stop() so accurate
        // numbers reach the summary even if the last tick came
        // moments before the user pressed Stop.
        liveStats = recorder.stats()
        mixerStats = audioMixer.snapshot()

        let summary = Self.buildRecordingSummary(rec: liveStats, mix: mixerStats)
        lastRecordingSummary = summary
        status = url.map { "Saved → \($0.lastPathComponent)  ·  \(summary)" } ?? "Recording stopped (no file)  ·  \(summary)"

        // Phase 4.6 — open the file we just wrote and confirm what
        // tracks actually made it in. Async so we don't block the
        // UI; updates lastFileProbeSummary + status when done.
        if let url {
            Task { await self.probeRecordedFile(url) }
        }
    }

    /// Phase 4.6.4 — readable summary built from the final
    /// snapshots. Includes per-channel state and any errors so a
    /// silent-recording cause shows itself without needing the
    /// console.
    private static func buildRecordingSummary(rec: RecorderStats, mix: AudioMixerStats) -> String {
        let recPart = "v=\(rec.videoAccepted) a=\(rec.audioAccepted) drop(pre/notReady/reject)=\(rec.audioDroppedPreAnchor)/\(rec.audioDroppedNotReady)/\(rec.audioAppendRejected)"
        let mixPart = "mix=\(mix.mixedFramesEmitted)f ticks=\(mix.ticks)"
        let chPart = mix.channels.map { ch -> String in
            var s = "\(ch.label):"
            if ch.deviceLabel != "—" {
                s += "[\(ch.deviceLabel)]"
            }
            s += ch.running ? "ON" : "OFF"
            if ch.nativeSampleRate > 0 {
                s += " \(Int(ch.nativeSampleRate))Hz×\(ch.nativeChannels)"
            }
            s += " push=\(ch.convertedFramesPushed) pull=\(ch.framesPulledByMixer) zf=\(ch.zeroFillEvents)"
            if let err = ch.lastError {
                s += " ERR=\(err)"
            }
            return s
        }.joined(separator: " · ")
        return "\(recPart) · \(mixPart) · \(chPart)"
    }

    /// Phase 4.6 — open the saved .mov and report what's in it.
    /// The single most common silent-recording cause is "audio track
    /// missing entirely." This makes that condition impossible to
    /// miss.
    private func probeRecordedFile(_ url: URL) async {
        // Phase 4.6.2 — AVAsset(url:) deprecated in macOS 15.0.
        // AVURLAsset is the supported entry point; it inherits from
        // AVAsset so loadTracks/load(.duration) still apply.
        let asset = AVURLAsset(url: url)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            let dur = CMTimeGetSeconds(duration)

            var audioDetail = "audio: NONE"
            if let aTrack = audioTracks.first {
                let aDur = try await aTrack.load(.timeRange).duration
                let aSeconds = CMTimeGetSeconds(aDur)
                let formats = try await aTrack.load(.formatDescriptions)
                var fmtSummary = "?"
                if let fmt = formats.first {
                    if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                        let asbd = asbdPtr.pointee
                        fmtSummary = "\(Int(asbd.mSampleRate))Hz × \(asbd.mChannelsPerFrame)ch / id=\(asbd.mFormatID)"
                    }
                }
                audioDetail = String(format: "audio: %.2fs / %@", aSeconds, fmtSummary)
            }

            let probeSummary = String(format: "Probe → %.2fs total · video tracks=%d · %@", dur, videoTracks.count, audioDetail)
            lastFileProbeSummary = probeSummary
            // Phase 4.6.4 — combine with recording summary so the
            // final status shows BOTH "what we tried to record" and
            // "what's actually in the file." Newline so each piece
            // gets its own line in the multi-line StatusBar.
            if let pre = lastRecordingSummary {
                status = "\(pre)\n\(probeSummary)"
            } else {
                status = probeSummary
            }
            print("Recaptr file probe: \(url.path) → \(probeSummary)")
        } catch {
            let s = "Probe failed: \(error.localizedDescription)"
            lastFileProbeSummary = s
            if let pre = lastRecordingSummary {
                status = "\(pre)\n\(s)"
            } else {
                status = s
            }
            print("Recaptr file probe error: \(error)")
        }
    }

    /// Phase 4.9 — single-channel: snapshot UI state into the mixer's
    /// channel before mixer.start() (called from startPreview).
    private func configureMixerFromUIState() {
        let ch1 = audioMixer.channel(at: 0)
        ch1?.deviceUniqueID = ch1DeviceID
        ch1?.deviceLabel = label(forAudioDeviceID: ch1DeviceID)
        ch1?.gain = Float(ch1Gain)
        ch1?.enabled = ch1Enabled && (ch1DeviceID != nil)
        ch1?.monitorEnabled = monitorEnabled
        ch1?.monitorVolume = Float(monitorVolume)
    }

    private func label(forAudioDeviceID id: String?) -> String {
        guard let id else { return "—" }
        return availableAudioSources.first(where: { $0.id == id })?.name ?? id
    }

    // MARK: - Stats polling

    private func startStatsTimer() {
        stopStatsTimer()
        // Phase 4.6.2 — guard-let inside the closure so the Task
        // captures an immutable `let`, not the weak `var` optional
        // (Swift 6 strict concurrency).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.tickStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recorderStatsTimer = timer
    }

    private func stopStatsTimer() {
        recorderStatsTimer?.invalidate()
        recorderStatsTimer = nil
    }

    private func tickStats() {
        // Phase 4.7 — mixer stats refresh whenever the mixer is
        // running (preview AND recording). Recorder stats and the
        // elapsed timer only refresh during actual recording.
        if audioMixer.running {
            mixerStats = audioMixer.snapshot()
        }

        guard let started = recordingStartedAt else { return }
        recordingElapsed = Date().timeIntervalSince(started)
        let snapshot = recorder.stats()
        liveStats = snapshot

        // Surface a writer failure mid-recording so a long session
        // doesn't burn 20 minutes producing nothing.
        if snapshot.writerStatus == .failed {
            let msg = snapshot.writerErrorDescription ?? "writer failed"
            status = "Writer failed mid-recording: \(msg)"
            Task { await self.stopRecording() }
        }
    }
}
