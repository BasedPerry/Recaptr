//
//  MainViewModel.swift
//  Recaptr
//
//  Central viewmodel and single source of truth for the UI. Owns the
//  DeviceCatalog, preview sample-buffer layer, Recorder, AudioMixer,
//  and the active CameraCaptureService / ScreenCaptureService, plus
//  user-facing state (selected source, gain, monitor, recording
//  status, permission flags, markers, last file probe).
//
//  Two pipelines feed the recorder:
//    - Camera sources push frames through CameraCaptureService and
//      audio through the AudioMixer (mic capture).
//    - Screen / window sources push frames AND audio from the same
//      SCStream (system loopback), bypassing the mixer.
//
//  The AudioMixer is N-channel internally; the UI currently exposes a
//  single audio input plus a live monitor toggle. The mixer's lifecycle
//  is scoped to preview, so VU meters and the monitor work before any
//  recording starts.
//

import Foundation
import Combine
import SwiftUI
import AppKit
import AVFoundation
import CoreImage          // CIImage → CGImage for PNG screenshots
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

// MARK: - Frame cache
//
// Thread-safe holder for the most recent preview CVPixelBuffer. Camera
// and screen services write on their capture queues; the @MainActor
// screenshot path reads on demand. Not @MainActor so writers don't
// have to hop threads; marked @unchecked Sendable because all access
// is serialized through the NSLock.
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

    /// User-selected save location: security-scoped bookmark in
    /// UserDefaults with a sandbox-container fallback. UI surfaces
    /// `displayLabel` / `displayPath` / `hasUserLocation`; startRecording
    /// resolves the actual directory via `resolveSaveDirectory()`.
    @Published var recordingStorage = RecordingStorage()

    // Channel 1: source audio (capture card HDMI audio, or the
    // camera's paired mic). Auto-selected to match the video source.
    @Published var ch1DeviceID: String?
    @Published var ch1Gain: Double = 1.0
    @Published var ch1Enabled: Bool = true

    // Channel 2: commentary mic. Off until the user picks a device.
    // Never auto-selected, and not routed to the monitor (hearing
    // your own voice back with latency is distracting).
    @Published var ch2DeviceID: String?
    @Published var ch2Gain: Double = 1.0
    @Published var ch2Enabled: Bool = true

    // Video settings, remembered between launches.
    @Published var videoQuality: VideoQuality =
        VideoQuality(savedValue: UserDefaults.standard.string(forKey: "RecaptrVideoQuality")) {
        didSet { UserDefaults.standard.set(videoQuality.rawValue, forKey: "RecaptrVideoQuality") }
    }
    /// Camera / capture card resolution. Auto = highest at 60 fps.
    @Published var captureResolution: CaptureResolution =
        CaptureResolution(rawValue: UserDefaults.standard.string(forKey: "RecaptrCaptureResolution") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(captureResolution.rawValue, forKey: "RecaptrCaptureResolution") }
    }
    /// Size actually being captured, for Settings and file-size math.
    var activeCaptureSize: CMVideoDimensions? {
        isPreviewing && activeDims.width > 0 ? activeDims : nil
    }

    /// Opt-in; changes the image, so off by default.
    @Published var lowLightNoiseReduction: Bool =
        UserDefaults.standard.bool(forKey: "RecaptrLowLightNoiseReduction") {
        didSet { UserDefaults.standard.set(lowLightNoiseReduction, forKey: "RecaptrLowLightNoiseReduction") }
    }
    /// Opt-in rolling 15 s buffer for screen and window sources.
    /// Off by default: Recaptr doesn't keep capture around unasked.
    @Published var instantReplay: Bool =
        UserDefaults.standard.bool(forKey: "RecaptrInstantReplay") {
        didSet { UserDefaults.standard.set(instantReplay, forKey: "RecaptrInstantReplay") }
    }
    /// True while the current screen source is buffering a replay.
    @Published var replayAvailable = false

    /// Whether the current camera supports low-light noise reduction.
    /// The Settings toggle only appears when it does.
    @Published var lowLightNoiseReductionSupported = false

    // Live audio monitor (foldback to the system default output).
    @Published var monitorEnabled: Bool = false
    @Published var monitorVolume: Double = 1.0  // 0…1.5

    @Published var isPreviewing = false
    @Published var isRecording = false
    @Published var status: String = "Idle"
    @Published var lastRecordedFile: URL?

    // Telemetry surfaced to the UI.
    @Published var recordingElapsed: TimeInterval = 0
    @Published var liveStats: RecorderStats = RecorderStats()
    @Published var mixerStats: AudioMixerStats = AudioMixerStats()

    @Published var audioPermissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var lastFileProbeSummary: String?

    /// Screen Recording TCC state. CoreGraphics exposes this as a bare
    /// Bool via `CGPreflightScreenCaptureAccess()` (not the 4-state
    /// `AVAuthorizationStatus` enum). TCC quirk: granting Screen
    /// Recording typically only takes effect for `SCStream` after the
    /// app is relaunched.
    @Published var screenCapturePermissionGranted: Bool = false

    /// Preserves recorder + mixer counters past the file-probe
    /// completion. The probe's status update would otherwise overwrite
    /// the only place those counters were surfaced.
    @Published var lastRecordingSummary: String?

    // Observers retained so they can be removed in deinit.
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Fires when any `AVCaptureDevice` is unplugged. The handler checks
    /// whether the unplugged device was the active source and stops
    /// cleanly if so.
    private var deviceDisconnectObserver: NSObjectProtocol?

    /// Fires when a new `AVCaptureDevice` appears (replug). Refreshes
    /// the catalog so the device shows up in the source dropdown, and
    /// auto-prefers a capture card when the current source is nil or a
    /// Continuity Camera fallback.
    private var deviceConnectObserver: NSObjectProtocol?

    // Combine subscriptions for live gain / monitor / permission state.
    private var cancellables = Set<AnyCancellable>()

    let previewSinkLayer = SampleBufferPreviewLayer(frame: .zero)

    /// Most recent preview frame, cached on every video sample from the
    /// camera or screen service. Read on demand by `captureScreenshot()`.
    /// Cleared in `stopPreview()` so a stale frame from a previous
    /// source can't accidentally be saved as a screenshot.
    let frameCache = PreviewFrameCache()

    /// Clip markers dropped during a recording session, each a
    /// `recordingElapsed` timestamp in seconds. Cleared at
    /// `startRecording`. `dropMarker()` is called from both the in-app
    /// button and the menu-bar item.
    @Published var markers: [TimeInterval] = []

    private var cameraService: CameraCaptureService?
    private var screenService: ScreenCaptureService?
    private let recorder = Recorder()
    /// Plays SCStream system audio while monitoring a screen or
    /// window capture. The mic monitor lives on the AudioMixer channel.
    private let systemAudioMonitor = SystemAudioMonitor()
    /// Levels for system audio on the direct (no-mic) screen path,
    /// which never passes through the mixer.
    private let screenAudioLevels = LevelTracker()
    private let audioMixer: AudioMixer
    private var activeDims: CMVideoDimensions = .init(width: 0, height: 0)
    private var hasAudio = false  // Snapshot at startRecording — locked until stopRecording

    /// True when the active preview is a screen source with `SCStream`
    /// system audio wired (audio comes from the stream's `.audio`
    /// output, not the AudioMixer). Set in `startPreview`, cleared in
    /// `stopPreview`. Read by `startRecording` to populate `hasAudio`.
    @Published var hasScreenAudio: Bool = false

    /// True while `startPreview` is building the session, so live
    /// audio changes made during startup (auto-select) don't trigger a
    /// second restart; startup applies the current selection anyway.
    private var isStartingPreview = false

    private var recordingStartedAt: Date?
    private var recorderStatsTimer: Timer?

    init() {
        // Two-channel mixer: source audio + commentary mic.
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let sourceChannel = AudioInputChannel(label: "Audio", outputFormat: outputFormat)
        let micChannel = AudioInputChannel(label: "Mic", outputFormat: outputFormat)
        // SCStream system audio, fed in only when narrating over a
        // screen or window capture (see `startPreview`).
        let systemChannel = AudioInputChannel(label: "System", outputFormat: outputFormat, isExternal: true)
        self.audioMixer = AudioMixer(channels: [sourceChannel, micChannel, systemChannel])

        // Wire mixer → recorder.
        audioMixer.onMixedSampleBuffer = { [weak self] sb in
            self?.recorder.appendAudio(sb)
        }
        // Recoveries and failures surface on the status line.
        audioMixer.onChannelEvent = { [weak self] message in
            self?.status = message
        }
        // Per-source tracks. The recorder drops these unless the
        // recording was started with source tracks.
        audioMixer.onChannelSampleBuffer = { [weak self] label, sb in
            self?.recorder.appendAudio(sb, source: label)
        }

        // Push live gain changes into the mixer. Gain is read on every
        // tap callback, so updating the channel.gain Float is enough —
        // no engine restart required.
        // Device / enable changes apply live while previewing (the
        // Settings pickers used to be locked during preview, which is
        // always). Debounced so a burst of changes restarts once.
        Publishers.Merge4(
            $ch1DeviceID.map { _ in () }, $ch1Enabled.map { _ in () },
            $ch2DeviceID.map { _ in () }, $ch2Enabled.map { _ in () }
        )
        .dropFirst(4)
        .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
        .sink { [weak self] in self?.applyAudioSelectionChange() }
        .store(in: &cancellables)

        $ch2Gain
            .sink { [weak self] value in
                self?.audioMixer.channel(at: 1)?.gain = Float(value)
            }
            .store(in: &cancellables)
        $ch1Gain
            .sink { [weak self] value in
                self?.audioMixer.channel(at: 0)?.gain = Float(value)
            }
            .store(in: &cancellables)

        // Monitor toggle + volume wired live (same no-restart pattern).
        $monitorEnabled
            .sink { [weak self] enabled in
                self?.audioMixer.channel(at: 0)?.setMonitor(enabled: enabled)
                self?.systemAudioMonitor.setEnabled(enabled)
            }
            .store(in: &cancellables)
        $monitorVolume
            .sink { [weak self] value in
                self?.audioMixer.channel(at: 0)?.monitorVolume = Float(value)
                self?.systemAudioMonitor.setVolume(Float(value))
            }
            .store(in: &cancellables)

        // Permission-revocation watchers. The user can flip Privacy
        // & Security toggles mid-session; we stop preview/recording
        // cleanly so we don't stream silence or black frames.
        // `.dropFirst()` skips the initial-state emission so startup
        // doesn't trip the handler.
        $audioPermissionStatus
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleAudioPermissionChange(status)
                }
            }
            .store(in: &cancellables)
        $screenCapturePermissionGranted
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleScreenPermissionChange(granted)
                }
            }
            .store(in: &cancellables)

        // Log identity at startup so `tccutil reset Microphone <bundle>`
        // can be confirmed against the right identifier when debugging
        // permission issues.
        let bundleID = Bundle.main.bundleIdentifier ?? "<unknown>"
        let initialMic = AVCaptureDevice.authorizationStatus(for: .audio)
        let initialScreen = CGPreflightScreenCaptureAccess()
        screenCapturePermissionGranted = initialScreen
        print("Recaptr launched — bundle=\(bundleID), mic permission=\(Self.permissionLabel(initialMic)), screen recording=\(initialScreen ? "granted" : "not granted")")

        // Recheck permissions whenever the app comes back to front
        // (the user may have toggled them in System Settings).
        //
        // The `guard let strongSelf` inside the closure is required
        // for Swift 6 strict concurrency: the Task needs to capture an
        // immutable `let`, not a weak `var` optional.
        let center = NotificationCenter.default
        didBecomeActiveObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.recheckAudioPermission(reason: "app activated")
                strongSelf.recheckScreenCapturePermission(reason: "app activated")
            }
        }

        // Route AVCaptureDevice disconnect notifications through
        // handleDeviceDisconnect, which decides whether the unplugged
        // device was the active source and stops cleanly if so.
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

        // Route AVCaptureDevice connect notifications so the catalog
        // refreshes and we can auto-switch to a freshly-plugged capture
        // card when appropriate.
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

        // Populate catalog first, then auto-pick a startup source so
        // the picker sees a populated list.
        Task {
            await self.refreshCatalog()
            await MainActor.run {
                self.autoSelectStartupSource()
                // UI tests: `-RecaptrUITestMicInput <name>` binds the
                // mic channel to the first input whose name contains
                // <name>, so multi-source runs without clicking.
                if UserDefaults.standard.bool(forKey: "RecaptrUITesting"),
                   let want = UserDefaults.standard.string(forKey: "RecaptrUITestMicInput"),
                   let match = self.availableAudioSources.first(where: {
                       $0.name.localizedCaseInsensitiveContains(want)
                   }) {
                    self.ch2DeviceID = match.id
                }
            }
        }
        Task { await self.requestAudioPermissionIfNeeded() }
        // Screen Recording is requested on demand (see
        // `screenModeSelected`), not at launch, so camera-only users
        // never see the prompt.
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

    /// Fires the macOS microphone TCC prompt at app startup if the
    /// user hasn't seen it yet. Goes through
    /// `AVCaptureDevice.requestAccess(for: .audio)`, which uses the
    /// `NSMicrophoneUsageDescription` entitlement. Calling this
    /// explicitly is more reliable than letting `AVAudioEngine` trip
    /// the prompt later — when that path fails silently, the recording
    /// just contains silence with no user-facing signal.
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

    /// Re-poll the OS for the current mic permission state and update
    /// both the published flag and the status line. Called from the
    /// `NSApplication.didBecomeActive` observer and from a UI button.
    /// Does not fire a TCC prompt — for that, call
    /// `requestAudioPermissionIfNeeded()` (which only prompts on
    /// `.notDetermined`).
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

    /// Open System Settings directly to the Microphone privacy panel
    /// so the user doesn't have to navigate manually.
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

    // MARK: - Screen recording permission (TCC)

    /// Fires the macOS Screen Recording TCC prompt when needed. Routes
    /// through `CGRequestScreenCaptureAccess`, the canonical entry
    /// point for screen-capture permission.
    /// `CGPreflightScreenCaptureAccess` reports current state without
    /// prompting; `CGRequestScreenCaptureAccess` fires the prompt on
    /// first call and returns the user's decision.
    ///
    /// TCC quirk: even after the user grants Screen Recording in
    /// Settings, the calling process typically needs to be relaunched
    /// before the grant takes effect for `SCStream`. The status
    /// message surfaces this so the user knows quitting is part of
    /// the recipe.
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

    /// Called when the user switches to Window or Screen mode. Asks
    /// for Screen Recording the first time it's actually needed.
    func screenModeSelected() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        requestScreenCapturePermissionIfNeeded()
    }

    /// Re-poll Screen Recording permission. Called from the
    /// `NSApplication.didBecomeActive` observer (and can be called
    /// from a UI button). Does not trigger a prompt — only reads the
    /// current state.
    func recheckScreenCapturePermission(reason: String) {
        let current = CGPreflightScreenCaptureAccess()
        let was = screenCapturePermissionGranted
        screenCapturePermissionGranted = current
        if current != was {
            print("recheckScreenCapturePermission(\(reason)): \(was) → \(current)")
        }
        // Newly granted: list displays and windows now.
        if current, !was {
            Task { await self.refreshCatalog() }
        }
        if current, status.hasPrefix("Screen recording permission denied") {
            status = "Idle"
        }
    }

    /// Open System Settings directly to the Screen Recording privacy
    /// panel. Same fallback pattern as `openMicrophonePrivacyPane`.
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

    /// Exposes all video sources (cameras + displays + windows) to the
    /// picker. The `startPreview()` switch routes each kind to the
    /// right service.
    var availableMainSources: [VideoSource] {
        catalog.videoSources
    }

    var availableAudioSources: [AudioSource] {
        catalog.audioSources
    }

    /// Single-channel: armed when a device is selected and the toggle is on.
    private var anyChannelArmed: Bool {
        (ch1Enabled && ch1DeviceID != nil) || (ch2Enabled && ch2DeviceID != nil)
    }

    // MARK: - Auto audio selection

    /// Auto-pick Channel 1 to match the current video source.
    ///
    /// Camera mode: find an audio source whose name matches the camera
    /// (exact → camera-contains-audio → audio-contains-camera, all
    /// case-insensitive). Capture cards like the Elgato 4K X expose a
    /// paired mic with the same name; built-in cameras pair with
    /// "Built-in Microphone" etc. Setting `ch1DeviceID` flows through
    /// the existing mixer plumbing.
    ///
    /// Screen / Window mode: leave Ch1 alone. The user's commentary
    /// mic stays as configured, and system audio comes through SCStream
    /// loopback on a separate path.
    ///
    /// Idempotent — a no-op when the chosen audio source is already
    /// selected.
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
            // handled by SCStream's `.audio` output, not Ch1.
            break
        }
    }

    // MARK: - Fast audio level polling (for VU meter)
    //
    // The general `mixerStats` publisher updates on a 1 Hz timer —
    // fine for telemetry, too slow for a VU meter (which should feel
    // continuous at ~30 fps). `currentAudioLevels()` lets a view poll
    // at whatever cadence it wants without bumping the global stats
    // tick rate. `AudioMixer.snapshot()` is cheap (just reads atomics
    // computed per-buffer in the tap), so 30 Hz polling is fine.

    /// Channel 1 audio levels in dBFS. Returns nil when the mixer
    /// isn't running. Both values are smoothed inside the mixer.
    func currentAudioLevels() -> (rms: Float, peak: Float)? {
        sourceLevels()
    }

    /// Level of the main source's audio: the capture card / camera
    /// channel, or system audio for Screen and Window sources (through
    /// the mixer's System channel when a mic is armed, otherwise the
    /// direct path). Nil when nothing is flowing.
    func sourceLevels() -> (rms: Float, peak: Float)? {
        guard let src = selectedMainSource, isPreviewing else { return nil }
        if src.kind == .camera { return channelLevels(0) }
        return hasScreenAudio ? screenAudioLevels.levels() : channelLevels(2)
    }

    /// Level of the commentary mic, or nil when no mic is running.
    func micLevels() -> (rms: Float, peak: Float)? {
        micArmed ? channelLevels(1) : nil
    }

    /// True when a commentary mic is chosen (so the pill shows its meter).
    var hasMic: Bool { micArmed }

    // MARK: - Screenshot + Marker

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

    /// Append the current `recordingElapsed` time to `markers`. No-op
    /// when not recording. Markers live in memory and reset at the
    /// start of each new recording.
    /// Save the last 15 seconds of the current screen source (instant
    /// replay). Works whether or not a recording is running.
    func saveReplay() async {
        guard let svc = screenService, svc.isReplayBuffering else {
            status = instantReplay
                ? "Instant replay works with Screen and Window sources."
                : "Turn on Instant replay in Settings to save the last 15 seconds."
            return
        }
        do {
            let dir = try recordingStorage.resolveSaveDirectory()
            let url = try Recorder.makeOutputURL(in: dir, prefix: "Recaptr_Replay")
            try await svc.exportReplay(to: url)
            lastRecordedFile = url
            lastFileProbeSummary = nil
            // The status line should describe this clip, not the last
            // recording.
            lastRecordingSummary = nil
            status = "Replay saved → \(url.lastPathComponent)"
            await probeRecordedFile(url)
        } catch {
            status = "Replay failed: \(error.localizedDescription)"
        }
    }

    func dropMarker() {
        guard isRecording else { return }
        let t = recordingElapsed
        markers.append(t)
        // Written into the file as a chapter.
        recorder.addMarker()
        status = String(format: "Marker dropped at %02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: - Auto startup source

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

    // MARK: - Device disconnect handler

    /// Handles `AVCaptureDevice.wasDisconnectedNotification`. Only
    /// reacts when the disconnected device matches the active camera
    /// source — at which point we stop the recording cleanly (writer
    /// finalizes, partial file is preserved), stop preview, clear the
    /// selection, refresh the catalog so the gone device drops out of
    /// the list, and surface a status message.
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

        // Capture cards typically expose a paired audio device with
        // the same name — unplugging the card removes both the camera
        // and the mic. If `ch1DeviceID` points at a gone audio source,
        // clear it so the Audio picker doesn't carry an orphan
        // selection (which SwiftUI's `Picker` flags with a "selection
        // invalid and does not have an associated tag" warning).
        if let currentCh1 = ch1DeviceID,
           !availableAudioSources.contains(where: { $0.id == currentCh1 }) {
            ch1DeviceID = availableAudioSources.first?.id
        }
        // The mic is never substituted: if it's gone, it's off.
        if let currentCh2 = ch2DeviceID,
           !availableAudioSources.contains(where: { $0.id == currentCh2 }) {
            ch2DeviceID = nil
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
            // Wait for the paired audio device to register in CoreAudio
            // HAL before flipping the video source. The camera
            // notification fires before CoreAudio has registered the
            // audio counterpart; switching too early leaves the
            // AudioMixer unable to resolve the UID and the recording
            // ends up video-only. Most capture cards settle within a
            // few hundred milliseconds; cap the wait at 1.2 s.
            await waitForPairedAudio(matching: newSource, timeout: 1.2)

            if isPreviewing {
                stopPreview()
            }
            selectedMainSource = newSource
            status = "Capture card connected: \(newSource.name)"
            // Audio auto-select runs via the .onChange(of: selectedMainSource)
            // observer in ContentViewNext (same path used at launch).
        }
    }

    // MARK: - Permission revocation handlers

    /// Microphone permission changed. Only reacts to "no longer
    /// authorized" while previewing or recording — initial state
    /// transitions during startup are filtered by `.dropFirst()` on
    /// the publisher. Stops cleanly so the file is preserved up to
    /// the moment of revocation; surfaces a status message so the
    /// user knows why.
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

    /// Screen Recording permission changed. Only reacts when the
    /// active source is a screen / window — revoking Screen Recording
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
            // 150 ms between polls — responsive without hammering
            // AVFoundation.
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Timed out. Proceed anyway: the AudioMixer will log a
        // "No Core Audio device matches UID" warning and continue
        // without that channel — better than blocking indefinitely.
    }

    // MARK: - Preview

    func startPreview() async {
        isStartingPreview = true
        defer { isStartingPreview = false }
        stopPreview()

        // Recheck mic permission right before any capture work. If the
        // user just granted access in System Settings, this clears the
        // stale "denied" status.
        recheckAudioPermission(reason: "startPreview")

        guard let src = selectedMainSource else {
            status = "Select a source"
            return
        }

        // Screen sources need Screen Recording TCC. Surface the missing
        // permission state before SCStream errors out — it would, but
        // with a less-readable message.
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
                    // Stash the latest frame for the Screenshot button.
                    // Cheap pointer copy; CIImage conversion only
                    // happens when the user actually triggers a
                    // screenshot.
                    if let pb = CMSampleBufferGetImageBuffer(sb) {
                        self?.frameCache.store(pb)
                    }
                    self?.recorder.appendVideo(sb)
                }
                svc.lowLightNoiseReduction = lowLightNoiseReduction
                svc.preferredResolution = captureResolution
                dims = try await svc.start(cameraUniqueID: cameraID,
                                           previewSink: previewSinkLayer)
                lowLightNoiseReductionSupported = svc.lowLightNoiseReductionSupported
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
                // Exclude Recaptr's own windows from the captured
                // frame. Without this, capturing the display Recaptr
                // is running on creates an infinite-mirror artifact
                // (preview shows itself showing itself…).
                let myBundleID = Bundle.main.bundleIdentifier
                let myWindows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == myBundleID
                }
                let filter = SCContentFilter(display: display, excludingWindows: myWindows)
                let svc = makeScreenService(audioViaMixer: micArmed)
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
                let svc = makeScreenService(audioViaMixer: micArmed)
                dims = try await svc.start(filter: filter, previewSink: previewSinkLayer)
                screenService = svc
            }

            activeDims = dims
            isPreviewing = true
            scheduleUITestAutoRecordIfRequested()
            replayAvailable = screenService?.isReplayBuffering ?? false

            // Audio pipeline depends on source kind:
            //   .camera  → AudioMixer (mic capture)
            //   .screen* → SCStream's .audio output (system loopback)
            //
            // The mixer is bypassed entirely for screen sources so we
            // don't end up with two competing audio inputs at the
            // recorder. Mixing mic narration on top of system audio
            // would require routing SCStream audio + mic through the
            // mixer with per-source levels — not the current shape.
            let audioLabel: String
            switch src.kind {
            case .camera:
                hasScreenAudio = false
                // Start the audio mixer so VU meters work pre-record.
                // The mixer keeps running through Record / Stop; it
                // only stops when preview ends.
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
                if micArmed {
                    // Narration: system audio + mic through the mixer.
                    hasScreenAudio = false
                    configureMixerFromUIState(screenSource: true)
                    do {
                        try audioMixer.start()
                        audioLabel = " · audio: system + mic (mixer)"
                    } catch {
                        audioLabel = " · audio mixer failed: \(error.localizedDescription)"
                    }
                } else {
                    // System audio only: SCStream's .audio output goes
                    // straight to the recorder (`onAudioBuffer`).
                    hasScreenAudio = true
                    audioLabel = " · audio: SCStream system loopback"
                }
                // Recorder telemetry ticks either way.
                startStatsTimer()
            }

            status = "Previewing — \(src.name) (\(dims.width)×\(dims.height))\(audioLabel)"
        } catch {
            status = "Capture error: \(error.localizedDescription)"
        }
    }

    /// Factor screen-service construction so display and window cases
    /// share the same callback wiring.
    ///
    /// - `onRecordBuffer` pushes frames into the recorder and stashes
    ///   the latest pixel buffer for the Screenshot button.
    /// - `onAudioBuffer` wires SCStream system audio directly into the
    ///   recorder, bypassing the AudioMixer (mic-only path).
    /// - `onStreamStopped` tears down preview cleanly when the stream
    ///   dies (display disconnected, window closed mid-capture,
    ///   permission revoked while running).
    private func makeScreenService(audioViaMixer: Bool) -> ScreenCaptureService {
        let svc = ScreenCaptureService()
        svc.instantReplay = instantReplay
        svc.onRecordBuffer = { [weak self] sb in
            // Cache the latest pixel buffer for the Screenshot button
            // (same pattern as the camera path).
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                self?.frameCache.store(pb)
            }
            self?.recorder.appendVideo(sb)
        }
        // Without a mic, system audio goes straight to the recorder
        // with its own capture timestamps (tightest A/V sync). With a
        // mic, it goes through the mixer's System channel so the two
        // can be mixed.
        let systemChannel = audioMixer.channel(at: 2)
        svc.onAudioBuffer  = { [weak self] sb in
            if audioViaMixer {
                systemChannel?.pushExternal(sb)
            } else {
                self?.recorder.appendAudio(sb)
                self?.screenAudioLevels.feed(sb)
            }
            self?.systemAudioMonitor.feed(sb)
        }
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
        // Mixer + stats timer tear down with preview. The mixer's
        // lifecycle is scoped to preview, not recording.
        if audioMixer.running { audioMixer.stop() }
        stopStatsTimer()
        // Reset transient mixer stats so VU meters go dark when
        // preview is off (otherwise the last-known values linger).
        mixerStats = AudioMixerStats()

        cameraService?.stop()
        cameraService = nil
        lowLightNoiseReductionSupported = false

        // Tear down the screen service if one is active.
        // `SCStream.stopCapture` is async; hand it off to a Task so
        // `stopPreview()` stays sync. Nil the reference immediately so
        // any new `startPreview()` doesn't see the old one.
        if let svc = screenService {
            screenService = nil
            Task { await svc.stop() }
        }
        hasScreenAudio = false
        replayAvailable = false
        systemAudioMonitor.stop()

        previewSinkLayer.flush()
        // Clear the cached preview frame so a stale frame from this
        // source can't be saved as a "screenshot" after preview ends.
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

        // Fresh markers list for the new session.
        markers = []

        // Audio path forks on source kind. Screen sources use
        // `SCStream`'s `.audio` output (`hasScreenAudio`); camera
        // sources use the AudioMixer (already running from preview).
        // Either path produces an audio track in the file.
        hasAudio = hasScreenAudio || (audioMixer.running && audioMixer.hasAnyEnabledChannel)

        // Resolve the save directory before starting the writer.
        // User-selected folder when set and accessible, sandbox
        // container otherwise. Per-recording resolution is cheap
        // (one FS-existence check) and lets a newly-attached external
        // drive pick up without an app restart.
        let saveDir: URL
        do {
            saveDir = try recordingStorage.resolveSaveDirectory()
        } catch {
            status = "Save directory error: \(error.localizedDescription)"
            return
        }

        // Disk-space pre-check. 1080p60 H.264 averages ~135 MB/min
        // and 4K60 closer to 400 MB/min; aborting under 2 GB free
        // prevents starting a recording that would fail several
        // minutes in when the writer can't extend the file. Uses
        // `.volumeAvailableCapacityForImportantUsageKey` so iCloud,
        // Time Machine, and Spotlight reserved space is excluded.
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
            // Probe failed — don't block recording on this. The user
            // might be on a volume that doesn't report capacity
            // (e.g. a network mount with a bad responder). Better to
            // let the recorder try and fail honestly.
            print("Recaptr: disk space probe failed (continuing): \(error.localizedDescription)")
        }

        // Two or more live sources: also write each one to its own
        // track, so levels can be rebalanced in an editor.
        let mixedSources = hasScreenAudio ? [] : audioMixer.runningChannelLabels
        let sourceTracks = mixedSources.count >= 2 ? mixedSources : []

        do {
            let url = try await recorder.start(
                width: activeDims.width,
                height: activeDims.height,
                withAudio: hasAudio,
                sourceTracks: sourceTracks,
                quality: videoQuality,
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
            lastFileProbeSummary = nil
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
        // Mixer + stats timer keep running for ongoing preview /
        // monitoring. Only the recorder stops here.
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

        // Open the file we just wrote and confirm what tracks
        // actually made it in. Async so the UI doesn't block; updates
        // `lastFileProbeSummary` + status when done. Catches the
        // silent-recording case where the file lands but has no audio
        // track.
        if let url {
            Task { await self.probeRecordedFile(url) }
        }
    }

    /// Readable summary built from the final stat snapshots. Includes
    /// per-channel state and any errors so a silent-recording cause
    /// shows itself without needing the console.
    private static func buildRecordingSummary(rec: RecorderStats, mix: AudioMixerStats) -> String {
        var recPart = "v=\(rec.videoAccepted) a=\(rec.audioAccepted) drop(pre/notReady/reject)=\(rec.audioDroppedPreAnchor)/\(rec.audioDroppedNotReady)/\(rec.audioAppendRejected)"
        if rec.videoDroppedNotReady > 0 || rec.videoAppendRejected > 0 {
            recPart += " vdrop(notReady/reject)=\(rec.videoDroppedNotReady)/\(rec.videoAppendRejected)"
        }
        if rec.sourceTrackAccepted > 0 {
            recPart += " src=\(rec.sourceTrackAccepted)"
        }
        if let err = rec.lastAppendError {
            recPart += " appendErr=\(err)"
        }
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
            if ch.trimmedFrames > 0 {
                s += " trim=\(ch.trimmedFrames)"
            }
            if ch.recoveries > 0 {
                s += " recovered=\(ch.recoveries)(\(ch.lastRecoveryReason ?? "?"))"
            }
            if let err = ch.lastError {
                s += " ERR=\(err)"
            }
            return s
        }.joined(separator: " · ")
        return "\(recPart) · \(mixPart) · \(chPart)"
    }

    /// Open the saved .mov and report what's actually in it.
    /// "Audio track missing entirely" is a common silent-recording
    /// failure mode; this surfaces it on the status line so it can't
    /// be missed.
    private func probeRecordedFile(_ url: URL) async {
        // `AVAsset(url:)` was deprecated in macOS 15.0. `AVURLAsset`
        // is the supported entry point; it inherits from AVAsset so
        // `loadTracks` / `load(.duration)` still apply.
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

            // Clip markers live in a timed-metadata track (see
            // Recorder); report how many marker ranges it holds.
            var markerRanges = 0
            if let markerTrack = try await asset.loadTracks(withMediaType: .metadata).first {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: markerTrack, outputSettings: nil)
                let provider = reader.outputMetadataProvider(for: output)
                try reader.start()
                while try await provider.next() != nil { markerRanges += 1 }
            }
            var enabledAudio = 0
            for t in audioTracks where try await t.load(.isEnabled) { enabledAudio += 1 }
            var fps: Float = 0
            var videoMbps: Float = 0
            var transfer = "unset"
            var codec = "?"
            if let vTrack = videoTracks.first {
                fps = try await vTrack.load(.nominalFrameRate)
                videoMbps = try await vTrack.load(.estimatedDataRate) / 1_000_000
                if let desc = try await vTrack.load(.formatDescriptions).first {
                    codec = CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_HEVC ? "hevc" : "h264"
                }
                if let desc = try await vTrack.load(.formatDescriptions).first,
                   let tf = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    transfer = tf == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String) ? "709" : tf
                }
            }
            let probeSummary = String(format: "Probe → %.2fs total · video tracks=%d · fps=%.2f · video %@ %.1f Mbps · transfer=%@ · audio tracks=%d (enabled %d) · marker ranges=%d · %@",
                                      dur, videoTracks.count, fps, codec, videoMbps, transfer, audioTracks.count, enabledAudio, markerRanges, audioDetail)
            lastFileProbeSummary = probeSummary
            // Combine with the recording summary so the final status
            // shows both "what we tried to record" and "what's actually
            // in the file." Newline separates them in the Diagnostics
            // text in Settings > Recording.
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

    // MARK: - UI test hook: record without keystrokes

    /// `-RecaptrUITesting YES -RecaptrUITestAutoRecord <seconds>`
    /// records once, 3 s after preview starts, for <seconds>, then
    /// quits after the file probe prints. Lets a capture be verified
    /// from the command line without sending keystrokes.
    private var uiTestAutoRecordDone = false
    private func scheduleUITestAutoRecordIfRequested() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "RecaptrUITesting"), !uiTestAutoRecordDone else { return }
        let seconds = d.double(forKey: "RecaptrUITestAutoRecord")
        guard seconds > 0 else { return }
        uiTestAutoRecordDone = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await startRecording()
            try? await Task.sleep(for: .seconds(seconds))
            await stopRecording()
            try? await Task.sleep(for: .seconds(4))  // let the probe print
            print("RecaptrUITest: status → \(status)")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Live audio device changes

    /// Apply a changed device or enable selection while previewing.
    /// Camera sources restart only the audio mixer, so video keeps
    /// running. Screen sources route system audio differently with and
    /// without a mic, so arming or disarming the mic restarts the
    /// preview; changing which mic restarts only the mixer. Locked
    /// while recording (Settings disables the pickers).
    func applyAudioSelectionChange() {
        guard isPreviewing, !isRecording, !isStartingPreview,
              let src = selectedMainSource else { return }

        let screenSource = src.kind != .camera
        let wantsMixer = screenSource ? micArmed : true
        let usesMixer = !hasScreenAudio
        if screenSource, wantsMixer != usesMixer {
            Task { await startPreview() }
            return
        }
        guard !audioSelectionMatchesMixer(screenSource: screenSource) else { return }

        if audioMixer.running { audioMixer.stop() }
        configureMixerFromUIState(screenSource: screenSource)
        guard audioMixer.hasAnyEnabledChannel else {
            status = "Audio off"
            return
        }
        do {
            try audioMixer.start()
            status = "Audio updated"
        } catch {
            status = "Audio restart failed: \(error.localizedDescription)"
        }
    }

    /// True when the mixer already runs exactly the selected devices,
    /// so an echoed change (auto-select) costs nothing.
    private func audioSelectionMatchesMixer(screenSource: Bool) -> Bool {
        guard audioMixer.running,
              let ch1 = audioMixer.channel(at: 0),
              let ch2 = audioMixer.channel(at: 1) else { return false }
        let wantCh1 = !screenSource && ch1Enabled && ch1DeviceID != nil
        return ch1.enabled == wantCh1
            && (!wantCh1 || ch1.deviceUniqueID == ch1DeviceID)
            && ch2.enabled == micArmed
            && (!micArmed || ch2.deviceUniqueID == ch2DeviceID)
    }

    /// Live post-gain level for one mixer channel (0 = source audio,
    /// 1 = mic), for Settings meters. Nil when that channel isn't
    /// running.
    func channelLevels(_ index: Int) -> (rms: Float, peak: Float)? {
        guard audioMixer.running else { return nil }
        let snap = audioMixer.snapshot()
        guard snap.channels.indices.contains(index), snap.channels[index].running else { return nil }
        return (snap.channels[index].rmsDbfs, snap.channels[index].peakDbfs)
    }

    /// True when a commentary mic is chosen and switched on.
    private var micArmed: Bool { ch2Enabled && ch2DeviceID != nil }

    /// Snapshot UI state into the mixer's channels before
    /// `mixer.start()` (called from `startPreview`).
    ///
    /// Camera sources mix source audio (channel 1) with the mic.
    /// Screen sources mix SCStream system audio (the System channel)
    /// with the mic; channel 1 stays off because its device belongs to
    /// the camera path.
    private func configureMixerFromUIState(screenSource: Bool = false) {
        let ch1 = audioMixer.channel(at: 0)
        ch1?.deviceUniqueID = ch1DeviceID
        ch1?.deviceLabel = label(forAudioDeviceID: ch1DeviceID)
        ch1?.gain = Float(ch1Gain)
        ch1?.enabled = !screenSource && ch1Enabled && (ch1DeviceID != nil)
        ch1?.monitorEnabled = monitorEnabled
        ch1?.monitorVolume = Float(monitorVolume)

        let ch2 = audioMixer.channel(at: 1)
        ch2?.deviceUniqueID = ch2DeviceID
        ch2?.deviceLabel = label(forAudioDeviceID: ch2DeviceID)
        ch2?.gain = Float(ch2Gain)
        ch2?.enabled = micArmed
        ch2?.monitorEnabled = false

        // System audio is monitored by SystemAudioMonitor, not here.
        let system = audioMixer.channel(at: 2)
        system?.deviceLabel = "System audio"
        system?.enabled = screenSource && micArmed
        system?.monitorEnabled = false
    }

    private func label(forAudioDeviceID id: String?) -> String {
        guard let id else { return "—" }
        return availableAudioSources.first(where: { $0.id == id })?.name ?? id
    }

    // MARK: - Stats polling

    private func startStatsTimer() {
        stopStatsTimer()
        // The `guard let strongSelf` inside the closure is required
        // for Swift 6 strict concurrency: the Task needs to capture
        // an immutable `let`, not a weak `var` optional.
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
        // Mixer stats refresh whenever the mixer is running (preview
        // AND recording). Recorder stats and the elapsed timer only
        // refresh during actual recording.
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
