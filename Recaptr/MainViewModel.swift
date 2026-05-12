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
import CoreImage          // Phase 6.5 — CIImage → CGImage for PNG screenshots
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

// MARK: - Frame cache (Phase 6.5)
//
// Tiny thread-safe holder for the most recent preview CVPixelBuffer.
// Camera + screen services write to it on their capture queues (not
// main); the @MainActor screenshot path reads it on demand. CVPixelBuffer
// is a CFType — assignment is reference-counted and atomic at the
// storage level, but the read-then-act pattern still needs a lock.
//
// Not @MainActor so the capture-queue writers can store without
// hopping; marked @unchecked Sendable since we serialize all access
// through the NSLock.
final class PreviewFrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var pixelBuffer: CVPixelBuffer?

    func store(_ buffer: CVPixelBuffer) {
        lock.lock()
        pixelBuffer = buffer
        lock.unlock()
    }

    func latest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return pixelBuffer
    }

    func clear() {
        lock.lock()
        pixelBuffer = nil
        lock.unlock()
    }
}

@MainActor
final class MainViewModel: ObservableObject {

    @Published var catalog = DeviceCatalog()
    @Published var selectedMainSource: VideoSource?

    // Phase 7 sneak — owns the user-selected save location (security-
    // scoped bookmark in UserDefaults + sandbox fallback). UI surfaces
    // displayLabel/displayPath/hasUserLocation; startRecording resolves
    // the actual directory via resolveSaveDirectory().
    @Published var recordingStorage = RecordingStorage()

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

    // Phase 5.4 — screen recording TCC. Unlike AVAuthorizationStatus
    // (4-state enum), CoreGraphics exposes screen-capture permission
    // as a bare Bool via CGPreflightScreenCaptureAccess(). True =
    // bundle is in System Settings → Privacy & Security → Screen
    // Recording with the box ticked. Note the TCC-quirk: granting
    // screen recording often only takes effect after the app is
    // relaunched.
    @Published var screenCapturePermissionGranted: Bool = false

    // Phase 4.6.4 — preserve the recorder/mixer counters past the
    // probe completion. Without this, the probe's status update
    // overwrites the only place we surfaced them, and we lose the
    // post-recording diagnostic state.
    @Published var lastRecordingSummary: String?

    // Phase 4.6.1 — observers retained so they can be removed.
    private var didBecomeActiveObserver: NSObjectProtocol?

    // Phase 6.6.1 — camera disconnect observer. Fires when ANY
    // AVCaptureDevice is unplugged; the handler checks whether it
    // was the active source and stops cleanly if so.
    private var deviceDisconnectObserver: NSObjectProtocol?

    // Phase 6.6.1.1 — camera connect observer. Fires when a new
    // AVCaptureDevice appears (replug). Refreshes the catalog so
    // the device shows up in the source dropdown, and auto-prefers
    // the capture card when current source is nil or a Continuity
    // Camera fallback.
    private var deviceConnectObserver: NSObjectProtocol?

    // Phase 4.7 — Combine subscriptions for live gain.
    private var cancellables = Set<AnyCancellable>()

    let previewSinkLayer = SampleBufferPreviewLayer(frame: .zero)

    // Phase 6.5 — most recent preview frame, cached on every video
    // sample from camera or screen services. Read on demand by
    // captureScreenshot(). Survives across previews; cleared in
    // stopPreview() so a stale frame from a previous source can't
    // accidentally be saved as a screenshot.
    let frameCache = PreviewFrameCache()

    // Phase 6.5 — clip markers dropped during a recording session.
    // Each value is a recordingElapsed timestamp (seconds). Cleared
    // at startRecording, surfaced by the Phase 7 sidebar's markers
    // list. UI hits this via dropMarker() — same call from in-app
    // button and menu bar.
    @Published var markers: [TimeInterval] = []

    private var cameraService: CameraCaptureService?
    private var screenService: ScreenCaptureService?
    private let recorder = Recorder()
    private let audioMixer: AudioMixer
    private var activeDims: CMVideoDimensions = .init(width: 0, height: 0)
    private var hasAudio = false  // Snapshot at startRecording — locked until stopRecording

    /// Phase 5b — true when the active preview is a screen source with
    /// SCStream system audio wired (audio comes from the SCStream's
    /// .audio output, not the AudioMixer). Set in startPreview, cleared
    /// in stopPreview. Read by startRecording to populate `hasAudio` and
    /// surfaced in status text so it's obvious which audio pipeline is
    /// in play.
    @Published var hasScreenAudio: Bool = false

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

        // Phase 6.6.2 — permission revocation watchers. Both audio
        // and screen-recording permission status flow through their
        // own @Published properties (updated via recheckAudioPermission
        // / recheckScreenCapturePermission, which fire on app activation
        // among other places). Subscribing here catches the case where
        // the user revokes permission mid-session — in System Settings,
        // then comes back — and stops the active preview/recording
        // cleanly instead of letting it stream silence / black frames.
        $audioPermissionStatus
            .removeDuplicates()
            .dropFirst()    // skip the initial-state emission
            .sink { [weak self] status in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleAudioPermissionChange(status)
                }
            }
            .store(in: &cancellables)
        $screenCapturePermissionGranted
            .removeDuplicates()
            .dropFirst()    // skip the initial-state emission
            .sink { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleScreenPermissionChange(granted)
                }
            }
            .store(in: &cancellables)

        // Phase 4.6.1 — log identity at startup so we can verify
        // tccutil reset is targeting the right bundle.
        let bundleID = Bundle.main.bundleIdentifier ?? "<unknown>"
        let initialMic = AVCaptureDevice.authorizationStatus(for: .audio)
        let initialScreen = CGPreflightScreenCaptureAccess()
        screenCapturePermissionGranted = initialScreen
        print("Recaptr launched — bundle=\(bundleID), mic permission=\(Self.permissionLabel(initialMic)), screen recording=\(initialScreen ? "granted" : "not granted")")

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
                // Phase 5.4 — also recheck screen recording. The user
                // might have toggled it in Settings → Privacy & Security
                // → Screen Recording while we were backgrounded.
                strongSelf.recheckScreenCapturePermission(reason: "app activated")
            }
        }

        // Phase 6.6.1 — camera disconnect observer. Routes any
        // wasDisconnectedNotification through handleDeviceDisconnect,
        // which decides whether the disconnected device was the
        // active source and stops cleanly if so.
        deviceDisconnectObserver = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                await strongSelf.handleDeviceDisconnect(note)
            }
        }

        // Phase 6.6.1.1 — camera connect observer. Refreshes the
        // catalog when a new device appears, and auto-prefers a
        // capture card if the current source is nil or a Continuity
        // Camera fallback (creator just replugged their Elgato after
        // the iPhone Camera took over — switch back automatically).
        deviceConnectObserver = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                await strongSelf.handleDeviceConnect(note)
            }
        }

        // Phase 6.6.1 — refresh catalog, then auto-pick a startup
        // source (capture card preferred). Both happen inside the
        // same Task so the auto-pick sees a populated catalog.
        Task {
            await self.refreshCatalog()
            await MainActor.run { self.autoSelectStartupSource() }
        }
        Task { await self.requestAudioPermissionIfNeeded() }
        // Phase 5.4 — fire the screen recording TCC prompt at launch
        // so the user sees it once, like the mic prompt, instead of
        // hitting it the first time they pick a display source.
        Task { @MainActor in self.requestScreenCapturePermissionIfNeeded() }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let deviceDisconnectObserver {
            NotificationCenter.default.removeObserver(deviceDisconnectObserver)
        }
        if let deviceConnectObserver {
            NotificationCenter.default.removeObserver(deviceConnectObserver)
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

    // MARK: - Phase 5.4 — Screen recording permission (TCC)

    /// Phase 5.4 — fire the macOS screen recording TCC prompt when
    /// needed. Mirrors requestAudioPermissionIfNeeded but routes through
    /// CGRequestScreenCaptureAccess, which is the canonical entry point
    /// for screen-capture permission. CGPreflightScreenCaptureAccess
    /// reports current state without prompting; CGRequest fires the
    /// prompt on first call and returns the user's decision.
    ///
    /// TCC quirk: even after the user grants Screen Recording in
    /// Settings, the calling process often needs to be relaunched
    /// before the grant takes effect for SCStream. The status message
    /// surfaces this so the user knows quitting is part of the recipe.
    func requestScreenCapturePermissionIfNeeded() {
        if CGPreflightScreenCaptureAccess() {
            screenCapturePermissionGranted = true
            print("requestScreenCapturePermissionIfNeeded: already granted")
            return
        }
        print("requestScreenCapturePermissionIfNeeded: not granted, calling CGRequestScreenCaptureAccess…")
        let granted = CGRequestScreenCaptureAccess()
        screenCapturePermissionGranted = granted
        print("requestScreenCapturePermissionIfNeeded: CGRequestScreenCaptureAccess returned \(granted)")
        if !granted {
            status = "Screen recording permission denied — open System Settings → Privacy & Security → Screen Recording to enable, then quit and relaunch Recaptr."
        }
    }

    /// Phase 5.4 — re-poll screen recording permission. Called from
    /// the NSApplication.didBecomeActive observer (and can be called
    /// from a UI button). Does not trigger a prompt — only reads the
    /// current state.
    func recheckScreenCapturePermission(reason: String) {
        let current = CGPreflightScreenCaptureAccess()
        let was = screenCapturePermissionGranted
        screenCapturePermissionGranted = current
        if current != was {
            print("recheckScreenCapturePermission(\(reason)): \(was) → \(current)")
        }
        if current, status.hasPrefix("Screen recording permission denied") {
            status = "Idle"
        }
    }

    /// Phase 5.4 — open System Settings directly to the Screen Recording
    /// privacy panel. Same pattern as openMicrophonePrivacyPane.
    func openScreenCapturePrivacyPane() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
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

    /// Phase 5.3 — expose ALL video sources (cameras + displays +
    /// windows) to the picker. The startPreview() switch routes each
    /// kind to the right service. Previously camera-only (Phase 2–4).
    var availableMainSources: [VideoSource] {
        catalog.videoSources
    }

    var availableAudioSources: [AudioSource] {
        catalog.audioSources
    }

    /// Phase 4.9 — single-channel: armed when device selected + toggle on.
    private var anyChannelArmed: Bool {
        ch1Enabled && ch1DeviceID != nil
    }

    // MARK: - Auto audio selection

    /// Phase 6.2 / Task #16 — auto-pick Channel 1 to match the
    /// current video source.
    ///
    /// Behavior:
    ///   - Camera mode: find an audio source whose name matches the
    ///     camera (exact → camera-contains-audio → audio-contains-camera,
    ///     all case-insensitive). Elgato devices expose a mic with the
    ///     same name; built-in cameras pair with "Built-in Microphone"
    ///     etc. Setting `ch1DeviceID` flows through the existing mixer
    ///     plumbing, so anything that re-reads it (preview, recording,
    ///     UI) picks up the change.
    ///   - Screen / Window mode: do NOT touch Ch1. The user's
    ///     commentary mic stays as-configured, and system audio comes
    ///     through SCStream loopback (Phase 5b) on a separate path.
    ///
    /// Idempotent — if the chosen audio source is already selected,
    /// this method is a no-op (won't churn `status`).
    func autoSelectAudioForCurrentSource() {
        guard let src = selectedMainSource else { return }
        switch src.kind {
        case .camera:
            let match =
                availableAudioSources.first(where: { $0.name.caseInsensitiveCompare(src.name) == .orderedSame })
                ?? availableAudioSources.first(where: { src.name.localizedCaseInsensitiveContains($0.name) })
                ?? availableAudioSources.first(where: { $0.name.localizedCaseInsensitiveContains(src.name) })
            if let m = match, m.id != ch1DeviceID {
                ch1DeviceID = m.id
                status = "Audio auto-selected: \(m.name)"
            }
        case .screenDisplay, .screenWindow:
            // Leave Ch1 alone. Commentary mic stays; system audio is
            // handled by SCStream's .audio output, not Ch1.
            break
        }
    }

    // MARK: - Fast audio level polling (for VU meter)
    //
    // The general `mixerStats` publisher updates on a 1Hz timer — fine
    // for telemetry, way too slow for a VU meter (which should feel
    // continuous, ~30fps). `currentAudioLevels()` lets a view subscribe
    // at whatever cadence it wants without us bumping the global stats
    // tick rate. AudioMixer.snapshot() is cheap (just reads atomics
    // computed per-buffer in handleTap), so polling at 30Hz is fine.

    /// Channel 1 audio levels in dBFS. Returns nil when the mixer
    /// isn't running. Both values are smoothed inside the mixer.
    func currentAudioLevels() -> (rms: Float, peak: Float)? {
        guard audioMixer.running else { return nil }
        let snap = audioMixer.snapshot()
        guard let ch0 = snap.channels.first else { return nil }
        return (ch0.rmsDbfs, ch0.peakDbfs)
    }

    // MARK: - Screenshot + Marker (Phase 6.5)

    /// Errors surfaced from the screenshot path. Status line picks
    /// up the localizedDescription so users see what went wrong.
    enum ScreenshotError: LocalizedError {
        case noFrame
        case conversionFailed
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noFrame:            return "No preview frame available — start a preview first."
            case .conversionFailed:   return "Couldn't render the preview frame to PNG."
            case .writeFailed(let e): return "Couldn't write screenshot file: \(e.localizedDescription)"
            }
        }
    }

    /// Capture the most recent preview frame as PNG and write it to
    /// the user-picked save folder. Filename includes a UTC timestamp
    /// (matches the recording filename convention). Returns the URL
    /// of the file that was written.
    ///
    /// Why pull from frameCache instead of re-rendering the preview
    /// layer: the cache holds the raw CVPixelBuffer at source resolution
    /// (1080p, 4K, whatever the device is producing), independent of
    /// the on-screen preview's display size. The user gets a full-quality
    /// PNG, not a downscaled screenshot of a SwiftUI view.
    func captureScreenshot() async throws -> URL {
        guard let pixelBuffer = frameCache.latest() else {
            throw ScreenshotError.noFrame
        }

        // CVPixelBuffer → CIImage → CGImage → NSBitmapImageRep → PNG Data.
        // CIContext.createCGImage is the part that touches the GPU /
        // does the colorspace conversion; everything else is light.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ScreenshotError.conversionFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.conversionFailed
        }

        // Filename: Recaptr_Screenshot_2026-05-12T20-15-43Z.png
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+0000", with: "Z")
        let filename = "Recaptr_Screenshot_\(stamp).png"

        let saveDir: URL
        do {
            saveDir = try recordingStorage.resolveSaveDirectory()
        } catch {
            throw ScreenshotError.writeFailed(error)
        }
        let url = saveDir.appendingPathComponent(filename)

        do {
            try pngData.write(to: url)
        } catch {
            throw ScreenshotError.writeFailed(error)
        }

        status = "Screenshot saved: \(filename)"
        return url
    }

    /// Append the current recording elapsed time to markers. No-op
    /// when not recording. Phase 7c's right sidebar will surface
    /// these as a scrollable list; for now they live in memory and
    /// disappear when the next recording starts.
    func dropMarker() {
        guard isRecording else { return }
        let t = recordingElapsed
        markers.append(t)
        status = String(format: "Marker dropped at %02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: - Auto startup source (Phase 6.6.1)

    /// Picks a sensible default source on first launch (or any time
    /// the user lands at the "Select a source" hint). Preference:
    ///
    ///   1. Capture card (Elgato / Magewell / AverMedia / etc.)
    ///   2. Non-Continuity camera (built-in FaceTime HD, USB webcam)
    ///   3. Any camera at all (last resort — Continuity iPhone Camera)
    ///
    /// Screens and windows are never auto-picked — those require
    /// user intent (you wouldn't want Recaptr to silently grab a
    /// random display the moment it launches).
    func autoSelectStartupSource() {
        guard selectedMainSource == nil else { return }
        let cameras = catalog.videoSources.filter { $0.kind == .camera }
        guard !cameras.isEmpty else { return }

        let pick = cameras.first(where: { $0.isCameraCaptureCard })
            ?? cameras.first(where: { !$0.isContinuityCamera })
            ?? cameras.first

        if let chosen = pick {
            selectedMainSource = chosen
            status = "Source: \(chosen.name)"
            // Trigger the existing audio auto-select so Ch1 also
            // lands on the matching mic.
            autoSelectAudioForCurrentSource()
        }
    }

    // MARK: - Device disconnect handler (Phase 6.6.1)

    /// Posted by AVCaptureDevice when any capture device is unplugged.
    /// We only care when the disconnected device matches our active
    /// camera source — at which point we stop the recording cleanly
    /// (writer finalizes, partial file is preserved), stop preview,
    /// clear the selection, refresh the catalog so the gone-device
    /// drops out of the list, and surface an honest status message.
    @MainActor
    private func handleDeviceDisconnect(_ note: Notification) async {
        guard let device = note.object as? AVCaptureDevice else { return }
        // Only react if the unplugged device is the one currently in use.
        // Screen / window paths are handled separately by SCStream's
        // onStreamStopped delegate.
        guard let activeID = selectedMainSource?.cameraUniqueID,
              activeID == device.uniqueID else { return }

        let deviceName = device.localizedName
        let wasRecording = isRecording

        if wasRecording {
            // stopRecording finalizes the writer so the partial file
            // is playable. Without this the user loses everything.
            await stopRecording()
        }
        if isPreviewing {
            stopPreview()
        }

        // Clear the dead source — UI returns to the "Select a source"
        // hint state until the user picks another or replugs.
        selectedMainSource = nil

        status = wasRecording
            ? "Device disconnected: \(deviceName) — recording saved."
            : "Device disconnected: \(deviceName)"

        // Refresh so the unplugged device drops out of the catalog;
        // if a replacement is now available (different capture card,
        // built-in camera), the user can pick it from the pill.
        await catalog.refresh()

        // Phase 6.6.1.1 — capture cards often expose a paired audio
        // device with the same name. When the Elgato 4K X is yanked,
        // both its camera AND its mic disappear. If ch1DeviceID is now
        // pointing at a gone audio source, clear it so the Audio
        // picker doesn't carry an orphan selection (Apple's Picker
        // warns "selection invalid and does not have an associated tag").
        if let currentCh1 = ch1DeviceID,
           !availableAudioSources.contains(where: { $0.id == currentCh1 }) {
            ch1DeviceID = availableAudioSources.first?.id
        }
    }

    /// Posted by AVCaptureDevice when a new capture device is plugged
    /// in. Refreshes the catalog so the new device appears in the
    /// dropdown, then optionally auto-switches to it.
    ///
    /// Auto-switch policy: only override the current selection when
    /// (a) nothing is selected, or (b) the user is currently on a
    /// Continuity Camera and a capture card just appeared (creator
    /// replugged their Elgato after their iPhone took over the slot).
    /// Doesn't override an explicit user choice of a built-in camera
    /// or non-Continuity USB webcam.
    @MainActor
    private func handleDeviceConnect(_ note: Notification) async {
        guard let device = note.object as? AVCaptureDevice else { return }

        await catalog.refresh()

        // Find the catalog entry for the newly-connected device.
        // DeviceCatalog ids use the "camera:<uniqueID>" prefix; if
        // the catalog refresh hasn't yet seen the device, bail out
        // (the next launch / manual refresh will catch it).
        let newSourceID = "camera:\(device.uniqueID)"
        guard let newSource = catalog.videoSources.first(where: { $0.id == newSourceID }) else {
            return
        }

        let shouldAutoSwitch: Bool
        if selectedMainSource == nil {
            shouldAutoSwitch = newSource.isCameraCaptureCard
        } else if let current = selectedMainSource,
                  current.isContinuityCamera,
                  newSource.isCameraCaptureCard {
            shouldAutoSwitch = true
        } else {
            shouldAutoSwitch = false
        }

        if shouldAutoSwitch {
            // Phase 6.6.2 — wait for the paired audio device to also
            // appear in CoreAudio HAL before flipping the source. The
            // camera notification fires before CoreAudio has registered
            // the audio counterpart; switching too early leaves the
            // AudioMixer unable to resolve the UID and the recording
            // ends up video-only. Poll for the matching audio in the
            // catalog with a short timeout — most capture cards (Elgato,
            // Magewell) settle within 300–600ms.
            await waitForPairedAudio(matching: newSource, timeout: 1.2)

            if isPreviewing {
                stopPreview()
            }
            selectedMainSource = newSource
            status = "Capture card connected: \(newSource.name)"
            // Audio auto-select will run via the .onChange(of: selectedMainSource)
            // observer in ContentViewNext; same path used at launch.
        }
    }

    // MARK: - Permission revocation handlers (Phase 6.6.2)

    /// Microphone permission changed. Only react to "no longer
    /// authorized" while we're actively previewing or recording —
    /// initial state transitions during startup are handled by the
    /// .dropFirst() on the publisher. Stops cleanly so the file is
    /// preserved up to the moment of revocation; surfaces a status
    /// message so the user knows why.
    @MainActor
    private func handleAudioPermissionChange(_ status: AVAuthorizationStatus) async {
        guard status != .authorized else { return }
        guard isPreviewing || isRecording else { return }

        let wasRecording = isRecording
        if wasRecording {
            await stopRecording()
        }
        if isPreviewing {
            stopPreview()
        }
        status_setRevoked(
            wasRecording: wasRecording,
            label: "Microphone",
            settingsHint: "System Settings → Privacy & Security → Microphone"
        )
    }

    /// Screen recording permission changed. Only react when the
    /// active source is screen / window — revoking screen recording
    /// while previewing a camera shouldn't tear anything down.
    @MainActor
    private func handleScreenPermissionChange(_ granted: Bool) async {
        guard !granted else { return }
        // Only stop if we're on a screen / window path. Cameras don't
        // use TCC screen recording.
        let activeKind = selectedMainSource?.kind
        let onScreenSource = activeKind == .screenDisplay || activeKind == .screenWindow
        guard onScreenSource, isPreviewing || isRecording else { return }

        let wasRecording = isRecording
        if wasRecording {
            await stopRecording()
        }
        if isPreviewing {
            stopPreview()
        }
        status_setRevoked(
            wasRecording: wasRecording,
            label: "Screen recording",
            settingsHint: "System Settings → Privacy & Security → Screen Recording"
        )
    }

    /// Shared status-line composer for both permission handlers.
    /// Keeps the phrasing consistent.
    private func status_setRevoked(wasRecording: Bool, label: String, settingsHint: String) {
        if wasRecording {
            status = "\(label) permission revoked — recording stopped and saved. Re-enable in \(settingsHint), then restart preview."
        } else {
            status = "\(label) permission revoked — preview stopped. Re-enable in \(settingsHint), then restart."
        }
    }

    /// Poll `availableAudioSources` for an audio device whose name
    /// matches the given video source (same heuristic as the audio
    /// auto-select). Returns as soon as a match appears, or after
    /// `timeout` seconds. Refreshes the catalog on each poll tick.
    /// No-op if a match is already present.
    @MainActor
    private func waitForPairedAudio(matching source: VideoSource, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await catalog.refresh()
            let match = availableAudioSources.first(where: {
                $0.name.caseInsensitiveCompare(source.name) == .orderedSame ||
                source.name.localizedCaseInsensitiveContains($0.name) ||
                $0.name.localizedCaseInsensitiveContains(source.name)
            })
            if match != nil { return }
            // 150ms between polls — quick enough to feel responsive,
            // long enough that we're not hammering AVFoundation.
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Timed out — proceed anyway. The AudioMixer will log a
        // "No Core Audio device matches UID" warning and continue
        // without that channel; better than blocking indefinitely.
    }

    // MARK: - Preview

    func startPreview() async {
        stopPreview()

        // Phase 4.6.1 — recheck mic permission right before any
        // capture work. If the user just granted access in System
        // Settings, this clears the stale "denied" status.
        recheckAudioPermission(reason: "startPreview")

        guard let src = selectedMainSource else {
            status = "Select a source"
            return
        }

        // Phase 5.4 — screen sources need TCC Screen Recording. Surface
        // the missing-permission state before SCStream errors out
        // (it would, but with a less-readable message).
        if src.kind != .camera {
            recheckScreenCapturePermission(reason: "startPreview")
            guard screenCapturePermissionGranted else {
                status = "Screen recording permission denied — open System Settings → Privacy & Security → Screen Recording to enable, then quit and relaunch Recaptr."
                return
            }
        }

        do {
            let dims: CMVideoDimensions
            switch src.kind {

            case .camera:
                guard let cameraID = src.cameraUniqueID else {
                    status = "Camera source missing cameraUniqueID"
                    return
                }
                let svc = CameraCaptureService()
                svc.onRecordBuffer = { [weak self] sb in
                    // Phase 6.5 — also stash the latest frame so the
                    // Screenshot button can write it as PNG. Cheap
                    // pointer copy; CIImage conversion only happens
                    // when the user actually triggers a screenshot.
                    if let pb = CMSampleBufferGetImageBuffer(sb) {
                        self?.frameCache.store(pb)
                    }
                    self?.recorder.appendVideo(sb)
                }
                dims = try await svc.start(cameraUniqueID: cameraID,
                                           previewSink: previewSinkLayer)
                cameraService = svc

            case .screenDisplay:
                guard let targetID = src.displayID else {
                    status = "Display source missing displayID"
                    return
                }
                // Re-fetch SCShareableContent so we get fresh SCDisplay/
                // SCWindow objects (VideoSource only carries the IDs).
                // Cheap call — SCShareableContent caches internally.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == targetID }) else {
                    status = "Display \(targetID) no longer available — hit Refresh and reselect."
                    return
                }
                // Phase 5.5 — exclude Recaptr's own windows from the
                // captured frame. Without this, capturing the same
                // display Recaptr is running on creates an infinite-
                // mirror artifact (preview shows itself showing itself…).
                let myBundleID = Bundle.main.bundleIdentifier
                let myWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == myBundleID
                }
                let filter = SCContentFilter(display: display, excludingWindows: myWindows)
                let svc = makeScreenService()
                dims = try await svc.start(filter: filter, previewSink: previewSinkLayer)
                screenService = svc

            case .screenWindow:
                guard let targetID = src.windowID else {
                    status = "Window source missing windowID"
                    return
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == targetID }) else {
                    status = "Window \(targetID) no longer available — hit Refresh and reselect."
                    return
                }
                // SCContentFilter has a desktop-independent window
                // initializer specifically for the single-window case.
                // No exclusion needed — only the chosen window is in
                // the capture.
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let svc = makeScreenService()
                dims = try await svc.start(filter: filter, previewSink: previewSinkLayer)
                screenService = svc
            }

            activeDims = dims
            isPreviewing = true

            // Phase 5b — audio pipeline depends on source kind.
            //   .camera  → AudioMixer (mic capture, Phase 4.x path)
            //   .screen* → SCStream .audio output (system loopback)
            //
            // The mixer is bypassed entirely for screen sources so we
            // don't end up with two competing audio inputs at the
            // recorder. Mic-narration-on-top-of-system-audio is Phase 6
            // (will mix SCStream audio + mic via AudioMixer with per-
            // source levels).
            let audioLabel: String
            switch src.kind {
            case .camera:
                hasScreenAudio = false
                // Phase 4.7 — start the audio mixer so VU meters work
                // pre-record. Mixer keeps running through Record / Stop;
                // it only stops when preview ends.
                configureMixerFromUIState()
                if audioMixer.hasAnyEnabledChannel {
                    do {
                        try audioMixer.start()
                        audioLabel = " · audio: mixer ON"
                        startStatsTimer()
                    } catch {
                        audioLabel = " · audio mixer failed: \(error.localizedDescription)"
                    }
                } else {
                    audioLabel = " · no audio channels armed"
                }

            case .screenDisplay, .screenWindow:
                hasScreenAudio = true
                // SCStream's .audio output is already wired via
                // onAudioBuffer → recorder.appendAudio. The mixer
                // stays off. Start the stats timer so recorder
                // telemetry still ticks (audio frame counter, PTS
                // regression counter).
                audioLabel = " · audio: SCStream system loopback"
                startStatsTimer()
            }

            status = "Previewing — \(src.name) (\(dims.width)×\(dims.height))\(audioLabel)"
        } catch {
            status = "Capture error: \(error.localizedDescription)"
        }
    }

    /// Phase 5.3 — factor screen-service construction so display and
    /// window cases share the same callback wiring. Stream-stopped
    /// callback tears down preview cleanly when the stream dies
    /// (display disconnected, window closed mid-capture, permission
    /// revoked while running).
    /// Phase 5b — onAudioBuffer wires SCStream system audio directly
    /// into the recorder, bypassing the AudioMixer (mic-only path).
    private func makeScreenService() -> ScreenCaptureService {
        let svc = ScreenCaptureService()
        svc.onRecordBuffer = { [weak self] sb in
            // Phase 6.5 — cache the latest pixel buffer for the
            // Screenshot button. Same pattern as the camera path.
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                self?.frameCache.store(pb)
            }
            self?.recorder.appendVideo(sb)
        }
        svc.onAudioBuffer  = { [weak self] sb in self?.recorder.appendAudio(sb) }
        svc.onStreamStopped = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let reason = error?.localizedDescription ?? "unknown reason"
                self.status = "Screen capture stopped: \(reason)"
                self.stopPreview()
            }
        }
        return svc
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

        // Phase 5.3 — tear down the screen service if one is active.
        // SCStream.stopCapture is async; we hand it off to a Task so
        // stopPreview() stays sync. Nil the reference immediately so
        // any new startPreview() doesn't see the old one.
        if let svc = screenService {
            screenService = nil
            Task { await svc.stop() }
        }
        // Phase 5b — clear the screen-audio flag so the next preview
        // doesn't accidentally inherit it.
        hasScreenAudio = false

        previewSinkLayer.flush()
        // Phase 6.5 — clear cached preview frame so a stale frame
        // from this source can't be saved as a "screenshot" after
        // preview has ended.
        frameCache.clear()
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

        // Phase 6.5 — fresh markers list for the new session.
        markers = []

        // Phase 5b — audio path forks on source kind. Screen sources
        // use SCStream's .audio output (hasScreenAudio); camera sources
        // use the AudioMixer (already running from preview). Either
        // path produces an audio track in the file.
        hasAudio = hasScreenAudio || (audioMixer.running && audioMixer.hasAnyEnabledChannel)

        // Phase 7 sneak — resolve the save directory before starting
        // the writer. User-selected folder if set + accessible,
        // sandbox container otherwise. Resolution is fast (just an
        // FS-existence check) and worth doing per-recording so a
        // newly-attached external drive picks up without a restart.
        let saveDir: URL
        do {
            saveDir = try recordingStorage.resolveSaveDirectory()
        } catch {
            status = "Save directory error: \(error.localizedDescription)"
            return
        }

        // Phase 6.6.3 — disk space pre-check. 1080p60 H.264 sits around
        // 12–18 Mbps which is ~135 MB/min; 4K60 closer to 400 MB/min.
        // Aborting under 2GB free prevents the user from starting a
        // recording that's going to fail 5–15 minutes in when the
        // writer can't extend the file. Uses the
        // .volumeAvailableCapacityForImportantUsageKey so iCloud /
        // Time Machine / Spotlight indexing reserved space is excluded
        // from the calculation.
        let minFreeBytes: Int64 = 2_000_000_000
        do {
            let values = try saveDir.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            if let free = values.volumeAvailableCapacityForImportantUsage, free < minFreeBytes {
                let freeGB = Double(free) / 1_000_000_000
                status = String(
                    format: "Low disk space: %.1f GB free on save volume. Free up space before recording (need at least 2 GB).",
                    freeGB
                )
                return
            }
        } catch {
            // Probe failed — don't block the recording on this. The
            // user might be on a volume that doesn't report capacity
            // (network mount with bad responder, etc.). Better to let
            // the recorder try and fail honestly than to block here.
            print("Recaptr: disk space probe failed (continuing): \(error.localizedDescription)")
        }

        do {
            let url = try await recorder.start(
                width: activeDims.width,
                height: activeDims.height,
                withAudio: hasAudio,
                saveDirectory: saveDir
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
