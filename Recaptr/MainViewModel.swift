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
    /// Screen and window capture size cap. Auto = the source's own
    /// pixel size, up to 4K.
    @Published var screenResolution: ScreenResolution =
        ScreenResolution(rawValue: UserDefaults.standard.string(forKey: "RecaptrScreenResolution") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(screenResolution.rawValue, forKey: "RecaptrScreenResolution") }
    }
    /// Screen and window frame rate: 60 or 30.
    @Published var screenFrameRate: Int =
        UserDefaults.standard.integer(forKey: "RecaptrScreenFrameRate") == 30 ? 30 : 60 {
        didSet { UserDefaults.standard.set(screenFrameRate, forKey: "RecaptrScreenFrameRate") }
    }
    // MARK: Series / Episode naming

    /// Series (the game or show). Recordings go in a folder of this
    /// name, named "Series – Episode". Empty: the old timestamp names.
    @Published var seriesName: String = UserDefaults.standard.string(forKey: "RecaptrSeries") ?? "" {
        didSet { if !Self.isUITesting { UserDefaults.standard.set(seriesName, forKey: "RecaptrSeries") } }
    }
    /// Episode for the next (or current) recording. Blank: "Ep N" plus
    /// a generated title. Cleared after each recording.
    @Published var episodeName: String = ""
    /// Recently used series, newest first.
    @Published var seriesHistory: [String] = UserDefaults.standard.stringArray(forKey: "RecaptrSeriesHistory") ?? [] {
        didSet { if !Self.isUITesting { UserDefaults.standard.set(seriesHistory, forKey: "RecaptrSeriesHistory") } }
    }
    /// A Bool setting with a default when unset. `bool(forKey:)` also
    /// reads "YES"/"NO" given as launch arguments, which `as? Bool`
    /// doesn't (a -RecaptrShowCaptureOutline NO run left it on).
    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    /// Test runs share the real app's settings; naming changes made by
    /// test hooks must not leak into the user's next recording.
    private static let isUITesting = UserDefaults.standard.bool(forKey: "RecaptrUITesting")
    /// Name markers and blank episodes with Apple Intelligence.
    @Published var aiNamingEnabled: Bool =
        MainViewModel.bool("RecaptrAINaming", default: true) {
        didSet { UserDefaults.standard.set(aiNamingEnabled, forKey: "RecaptrAINaming") }
    }
    /// After-stop work (probe, naming, renaming, Final Cut file).
    private(set) var finalizeTask: Task<Void, Never>?

    /// Outline the display or window being captured (never recorded).
    @Published var showCaptureOutline: Bool =
        MainViewModel.bool("RecaptrShowCaptureOutline", default: true) {
        didSet {
            UserDefaults.standard.set(showCaptureOutline, forKey: "RecaptrShowCaptureOutline")
            if !showCaptureOutline { captureOutline.hide() }
            else if isPreviewing, let src = selectedMainSource { showOutline(for: src) }
        }
    }
    private let captureOutline = CaptureOutline()

    private func showOutline(for source: VideoSource) {
        guard showCaptureOutline else { return }
        if let id = source.displayID, source.kind == .screenDisplay {
            captureOutline.show(display: id)
        } else if let id = source.windowID, source.kind == .screenWindow {
            captureOutline.show(window: id)
        }
        captureOutline.setRecording(isRecording)
    }

    @Published var screenShowsCursor: Bool =
        MainViewModel.bool("RecaptrScreenShowsCursor", default: true) {
        didSet { UserDefaults.standard.set(screenShowsCursor, forKey: "RecaptrScreenShowsCursor") }
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
    /// Per-second recording readouts, in their own small observable so
    /// only the views that show them (timer pill, menu bar) update each
    /// second. When these were @Published here, every tick rebuilt the
    /// whole app: every window, Settings, and the menu bar item
    /// (profiling, 2026-09-27).
    let clock = RecordingClock()
    var recordingElapsed: TimeInterval {
        get { clock.elapsed }
        set { clock.elapsed = newValue }
    }
    /// Size of the file being written, refreshed once a second.
    var recordingBytes: Int64 {
        get { clock.bytes }
        set { clock.bytes = newValue }
    }
    /// File being written, for `recordingBytes`.
    private var recordingURL: URL?
    /// Diagnostics, refreshed each second but not published: nothing
    /// on screen shows them live (the summary is built at stop).
    var liveStats: RecorderStats = RecorderStats() {
        didSet { if clock.anchored != liveStats.sessionAnchored { clock.anchored = liveStats.sessionAnchored } }
    }
    var mixerStats: AudioMixerStats = AudioMixerStats()

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
    static let markerDebounce: TimeInterval = 1

    private var cameraService: CameraCaptureService?
    private var screenService: ScreenCaptureService?
    private let recorder = Recorder()
    /// Plays SCStream system audio while monitoring a screen or
    /// window capture. The mic monitor lives on the AudioMixer channel.
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
    /// ⌃⌥⌘B drops a marker from any app, registered only while
    /// recording so the combo is free the rest of the time.
    private var markerHotKey: GlobalHotKey?
    /// Held while recording so idle sleep can't cut a long capture
    /// short. Keeps the display awake too: with only system sleep
    /// blocked, the display slept after 10 idle minutes and the
    /// capture card stalled for ~1 s several times as it did (two
    /// takes, 2026-09-26/27).
    private var recordingActivity: NSObjectProtocol?
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
        // The monitor plays one channel: the camera's source audio, or
        // for screen and window captures the mic (see
        // `monitorChannelIndex`).
        $monitorEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                let target = self.monitorChannelIndex
                for index in 0...1 {
                    self.audioMixer.channel(at: index)?.setMonitor(enabled: enabled && index == target)
                }
            }
            .store(in: &cancellables)
        $monitorVolume
            .sink { [weak self] value in
                for index in 0...1 {
                    self?.audioMixer.channel(at: index)?.monitorVolume = Float(value)
                }
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
            // UI tests asking for a screen or window source: displays
            // and windows can arrive a moment after cameras, and
            // picking early silently fell back to a camera (which
            // skewed a profiling comparison, 2026-09-27). Wait for them.
            if Self.isUITesting, let want = UserDefaults.standard.string(forKey: "RecaptrUITestSource") {
                let kind: VideoSource.Kind = want == "display" ? .screenDisplay : .screenWindow
                for _ in 0..<20 where !self.catalog.videoSources.contains(where: { $0.kind == kind }) {
                    try? await Task.sleep(for: .milliseconds(250))
                    await self.refreshCatalog()
                }
            }
            await MainActor.run {
                self.autoSelectStartupSource()
                // UI tests: `-RecaptrUITestMicInput <name>` binds the
                // mic channel to the first input whose name contains
                // <name>, so multi-source runs without clicking.
                // `-RecaptrUITestSeries <name>` / `-RecaptrUITestEpisode
                // <name>` preset the naming fields (not saved; see
                // isUITesting).
                if Self.isUITesting {
                    if let series = UserDefaults.standard.string(forKey: "RecaptrUITestSeries") { self.seriesName = series }
                    if let episode = UserDefaults.standard.string(forKey: "RecaptrUITestEpisode") { self.episodeName = episode }
                }
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
        #if DEBUG
        // UI tests: `-RecaptrUITestProbeLatest YES` probes the newest
        // recording (for example one cut off by a force-quit), prints
        // what's in it, and quits.
        if Self.isUITesting, UserDefaults.standard.bool(forKey: "RecaptrUITestProbeLatest") {
            Task { @MainActor in
                if let newest = self.newestRecording() {
                    print("RecaptrUITest: probing \(newest.lastPathComponent)")
                    print("RecaptrUITest: " + MonitorLagProbe.atoms(newest))
                    await self.probeRecordedFile(newest)
                    print("RecaptrUITest: " + (await MonitorLagProbe.videoGaps(newest)))
                }
                NSApp.terminate(nil)
            }
        }
        #endif
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
        // Exact time; recordingElapsed only ticks once a second.
        let t = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? recordingElapsed
        // One marker per second: extra presses (a mashed or held key)
        // are ignored. A 2026-09-27 take got five markers in 0.9 s.
        if let last = markers.last, t - last < Self.markerDebounce { return }
        markers.append(t)
        // Precise capture-clock time, for the .fcpxml.
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
        // UI tests: `-RecaptrUITestSource display|window:<name>` starts
        // on the first display, or the first window whose title
        // contains <name>, instead of a camera.
        let d = UserDefaults.standard
        if d.bool(forKey: "RecaptrUITesting"), let want = d.string(forKey: "RecaptrUITestSource") {
            let pick: VideoSource? = want == "display"
                ? catalog.videoSources.first { $0.kind == .screenDisplay }
                : catalog.videoSources.first {
                    $0.kind == .screenWindow
                        && $0.name.localizedCaseInsensitiveContains(String(want.dropFirst("window:".count)))
                }
            if let pick {
                selectedMainSource = pick
                return
            }
        }
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
                // Excluding the app rather than its current windows also
                // keeps out windows opened later (the capture outline).
                let myBundleID = Bundle.main.bundleIdentifier
                let filter: SCContentFilter
                if let me = content.applications.first(where: { $0.bundleIdentifier == myBundleID }) {
                    filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
                } else {
                    let myWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == myBundleID }
                    filter = SCContentFilter(display: display, excludingWindows: myWindows)
                }
                let svc = makeScreenService(audioViaMixer: micArmed)
                let size = screenResolution.fit(ScreenResolution.pixelSize(of: display))
                dims = try await svc.start(filter: filter, previewSink: previewSinkLayer, size: size,
                                           frameRate: screenFrameRate, showsCursor: screenShowsCursor)
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
                let size = screenResolution.fit(ScreenResolution.pixelSize(of: window))
                dims = try await svc.start(filter: filter, previewSink: previewSinkLayer, size: size,
                                           frameRate: screenFrameRate, showsCursor: screenShowsCursor)
                screenService = svc
            }

            activeDims = dims
            isPreviewing = true
            showOutline(for: src)
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
        captureOutline.hide()

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
            markerHotKey = GlobalHotKey.marker { [weak self] in self?.dropMarker() }
            captureOutline.setRecording(true)
            recordingURL = url
            recordingBytes = 0
            warnedLowDisk = false
            warnedHot = false
            lastDiskCheck = .distantPast
            recordingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Recaptr is recording"
            )
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
        markerHotKey?.unregister()
        markerHotKey = nil
        captureOutline.setRecording(false)
        if let activity = recordingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            recordingActivity = nil
        }
        recordingStartedAt = nil
        recordingURL = nil
        lastRecordedFile = url

        // Take one final stats snapshot AFTER stop() so accurate
        // numbers reach the summary even if the last tick came
        // moments before the user pressed Stop.
        liveStats = recorder.stats()
        mixerStats = audioMixer.snapshot()

        var summary = Self.buildRecordingSummary(rec: liveStats, mix: mixerStats)
        // Why the take ended, when Recaptr ended it (disk full, writer
        // failure): first line of the status and of Diagnostics.
        if let reason = stopReason {
            summary = reason + "\n" + summary
            stopReason = nil
        }
        lastRecordingSummary = summary
        status = url.map { "Saved → \($0.lastPathComponent)  ·  \(summary)" } ?? "Recording stopped (no file)  ·  \(summary)"


        // Open the file we just wrote and confirm what tracks
        // actually made it in. Async so the UI doesn't block; updates
        // `lastFileProbeSummary` + status when done. Catches the
        // silent-recording case where the file lands but has no audio
        // track.
        if let url {
            let markerSeconds = recorder.lastMarkerSeconds
            let series = SessionNaming.sanitize(seriesName)
            let episode = episodeName
            episodeName = ""
            finalizeTask = Task {
                await self.probeRecordedFile(url)
                await self.finalizeRecording(url, markerSeconds: markerSeconds, series: series, typedEpisode: episode)
            }
        }
    }

    /// Name markers (and a blank episode) with Apple Intelligence, move
    /// the file into its series folder as "Series – Episode", and write
    /// the Final Cut file with the marker names and the series as its
    /// event.
    private func finalizeRecording(_ url: URL, markerSeconds: [Double], series: String, typedEpisode: String) async {
        let useAI = aiNamingEnabled && MarkerNamer.isAvailable
        var labels: [String?] = markerSeconds.map { _ in nil }
        if useAI, !markerSeconds.isEmpty {
            status += "\nNaming \(markerSeconds.count) marker\(markerSeconds.count == 1 ? "" : "s")…"
            labels = await MarkerNamer.labels(for: url, markerSeconds: markerSeconds,
                                              series: series.isEmpty ? nil : series)
        }

        var finalURL = url
        if !series.isEmpty {
            let folder = SessionNaming.seriesFolder(root: url.deletingLastPathComponent(), series: series)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                let number = SessionNaming.nextEpisodeNumber(existing: existing, series: series)
                var generated: String?
                if useAI, SessionNaming.sanitize(typedEpisode).isEmpty {
                    generated = await MarkerNamer.episodeTitle(fromLabels: labels.compactMap { $0 }, series: series)
                }
                let episode = SessionNaming.episode(typed: typedEpisode, number: number, generatedTitle: generated)
                let target = SessionNaming.uniqueURL(in: folder, base: SessionNaming.baseName(series: series, episode: episode), ext: "mov")
                try FileManager.default.moveItem(at: url, to: target)
                finalURL = target
                lastRecordedFile = target
                status += "\nSaved as \(series)/\(target.lastPathComponent)"
                seriesHistory = [series] + seriesHistory.filter { $0 != series }.prefix(9)
            } catch {
                status += "\nCouldn't file it under \(series): \(error.localizedDescription)"
            }
        }

        let markers = markerSeconds.enumerated().map { index, seconds in
            (title: labels[index] ?? "Marker \(index + 1)", seconds: seconds)
        }
        await writeFinalCutMarkers(for: finalURL, markers: markers, eventName: series.isEmpty ? nil : series)
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
        var mixPart = "mix=\(mix.mixedFramesEmitted)f ticks=\(mix.ticks)"
        if mix.catchUpChunks > 0 {
            mixPart += " caughtUp=\(mix.catchUpChunks)"
        }
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
            if let ppm = ch.driftPPM {
                s += String(format: " drift=%+.1fppm(-%d/+%d)", ppm, ch.driftDrops, ch.driftRepeats)
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

    /// A recording with markers (or in a series) gets a .fcpxml beside
    /// it; that's where Final Cut picks up the markers and the event.
    private func writeFinalCutMarkers(for url: URL, markers: [(title: String, seconds: Double)],
                                      eventName: String?) async {
        do {
            if let xml = try await FinalCutMarkers.writeIfNeeded(for: url, markers: markers, eventName: eventName) {
                if UserDefaults.standard.bool(forKey: "RecaptrUITesting"),
                   let text = try? String(contentsOf: xml, encoding: .utf8) {
                    print("RecaptrUITest: fcpxml BEGIN\n\(text)RecaptrUITest: fcpxml END")
                }
                status += "\nFinal Cut markers → \(xml.lastPathComponent) (double-click to import)"
                lastFileProbeSummary = (lastFileProbeSummary ?? "") + " · fcpxml=\(xml.lastPathComponent)"
            }
        } catch {
            status += "\nCouldn't write Final Cut markers: \(error.localizedDescription)"
        }
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

            // Every audio track's length: per-source tracks must match
            // each other and the video, or they drift out of sync.
            var trackLengths: [String] = []
            for t in audioTracks {
                trackLengths.append(String(format: "%.2f", try await t.load(.timeRange).duration.seconds))
            }
            let videoLength = try await videoTracks.first?.load(.timeRange).duration.seconds ?? 0
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
            let probeSummary = String(format: "Probe → %.2fs total · video tracks=%d · fps=%.2f · video %@ %.1f Mbps · transfer=%@ · audio tracks=%d (enabled %d) · markers=%d · lengths video %.2f audio [%@] · %@",
                                      dur, videoTracks.count, fps, codec, videoMbps, transfer, audioTracks.count, enabledAudio, recorder.lastMarkerSeconds.count, videoLength, trackLengths.joined(separator: ", ") as NSString, audioDetail)
            lastFileProbeSummary = probeSummary
            #if DEBUG
            if Self.isUITesting {
                let r = liveStats
                lastFileProbeSummary = probeSummary + " · " + (await MonitorLagProbe.videoGaps(url))
                    + " · vdrop notReady=\(r.videoDroppedNotReady) reject=\(r.videoAppendRejected) ptsRegression=\(r.videoDroppedPtsRegression) accepted=\(r.videoAccepted)"
            }
            #endif
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
        // `-RecaptrUITestResetNaming YES` clears the saved series and
        // history (cleanup after earlier test runs saved them).
        if d.bool(forKey: "RecaptrUITestResetNaming") {
            UserDefaults.standard.removeObject(forKey: "RecaptrSeries")
            UserDefaults.standard.removeObject(forKey: "RecaptrSeriesHistory")
            seriesName = ""
            seriesHistory = []
            print("RecaptrUITest: naming reset")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await startRecording()
            // `-RecaptrUITestMonitor YES` monitors the source during
            // the take (latency tests: the mic hears the speakers).
            // Outline check: is a Recaptr window up at status-bar level?
            let mine = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
                .compactMap { $0[kCGWindowLayer as String] as? Int }
            print("RecaptrUITest: own window layers \(mine.sorted())")
            // The capture outline: a Recaptr window at status-bar level
            // the size of a display (the menu bar item is also at that
            // level, so layer alone proves nothing).
            let outlines = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 25
                    && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 800 }
            print("RecaptrUITest: capture outline windows \(outlines.count)")
            if d.bool(forKey: "RecaptrUITestMonitor") {
                // `-RecaptrUITestMonitorVolume 0` keeps a mic monitor
                // silent (no feedback through speakers).
                if let v = d.object(forKey: "RecaptrUITestMonitorVolume") as? NSNumber { monitorVolume = v.doubleValue }
                else if let v = d.string(forKey: "RecaptrUITestMonitorVolume"), let n = Double(v) { monitorVolume = n }
                monitorEnabled = true
            }
            #if DEBUG
            if d.bool(forKey: "RecaptrUITestMeasureMonitorLag") {
                Task { @MainActor [weak self] in
                    for _ in 0..<Int(seconds / 10) {
                        try? await Task.sleep(for: .seconds(10))
                        if let ring = self?.audioMixer.channel(at: 0)?.monitorRing {
                            print("RecaptrUITest: monitor ring fill=\(ring.fill)")
                        }
                        if let a = self?.audioMixer.channel(at: 0)?.takeBacklogAverage(),
                           let m = self?.audioMixer.channel(at: 1)?.takeBacklogAverage() {
                            print(String(format: "RecaptrUITest: backlog audio=%.0f mic=%.0f mic-audio=%.1fms", a, m, (m - a) / 48))
                        }
                    }
                }
            }
            #endif
            // `-RecaptrUITestAutoMarkers <n>` drops n markers spread
            // evenly through the take.
            let markerCount = max(0, d.integer(forKey: "RecaptrUITestAutoMarkers"))
            let slice = seconds / Double(markerCount + 1)
            for _ in 0..<markerCount {
                try? await Task.sleep(for: .seconds(slice))
                dropMarker()
            }
            try? await Task.sleep(for: .seconds(slice))
            await stopRecording()
            await finalizeTask?.value
            try? await Task.sleep(for: .seconds(1))
            #if DEBUG
            if let url = lastRecordedFile {
                print("RecaptrUITest: " + (await MonitorLagProbe.videoGaps(url)))
                print("RecaptrUITest: " + MonitorLagProbe.atoms(url))
                print("RecaptrUITest: " + (await MonitorLagProbe.greenEdge(url)))
            }
            if d.bool(forKey: "RecaptrUITestMeasureMonitorLag"), let url = lastRecordedFile {
                if let ring = audioMixer.channel(at: 0)?.monitorRing {
                    print("RecaptrUITest: monitor ring skips=\(ring.skips) underruns=\(ring.underruns)")
                }
                print("RecaptrUITest: " + (await MonitorLagProbe.measure(url)))
            }
            #endif
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
        // Called by 30 Hz meters: read the channel directly rather than
        // snapshotting every channel's counters.
        guard audioMixer.running else { return nil }
        return audioMixer.channel(at: index)?.levels()
    }

    #if DEBUG
    /// Newest .mov in the save folder (UI tests).
    private func newestRecording() -> URL? {
        guard let dir = try? recordingStorage.resolveSaveDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "mov" }.max { modified($0) < modified($1) }
    }
    #endif

    /// Mixer channel the monitor plays: the camera's source audio (0),
    /// or the mic (1) for screen and window captures. Nil when there
    /// is nothing worth monitoring (a screen capture without a mic).
    var monitorChannelIndex: Int? {
        guard let kind = selectedMainSource?.kind else { return nil }
        if kind == .camera { return 0 }
        return micArmed ? 1 : nil
    }

    /// Whether the monitor button does anything for this source.
    var canMonitor: Bool { monitorChannelIndex != nil }

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
        ch1?.monitorEnabled = monitorEnabled && !screenSource
        ch1?.monitorVolume = Float(monitorVolume)

        let ch2 = audioMixer.channel(at: 1)
        ch2?.deviceUniqueID = ch2DeviceID
        ch2?.deviceLabel = label(forAudioDeviceID: ch2DeviceID)
        ch2?.gain = Float(ch2Gain)
        ch2?.enabled = micArmed
        // Screen and window captures monitor the mic only: the system
        // audio already plays through the speakers, and monitoring it
        // too doubled everything (Brandon, 2026-09-27).
        ch2?.monitorEnabled = monitorEnabled && screenSource
        ch2?.monitorVolume = Float(monitorVolume)

        // System audio is never monitored (it's already audible).
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
        // Lets macOS batch this wake-up with others (energy).
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        recorderStatsTimer = timer
    }

    // MARK: - Recording health (disk space, heat)

    /// Free space left when a take is stopped cleanly rather than
    /// letting the writer fail on a full disk.
    static var stopBelowBytes: Int64 {
        // `-RecaptrUITestStopBelowGB <n>` raises it so tests can
        // trigger the stop without filling a drive.
        let override = UserDefaults.standard.double(forKey: "RecaptrUITestStopBelowGB")
        return isUITesting && override > 0 ? Int64(override * 1e9) : 1_000_000_000
    }
    static let warnBelowBytes: Int64 = 5_000_000_000
    private var lastDiskCheck = Date.distantPast
    private var warnedLowDisk = false
    private var warnedHot = false
    /// Set when Recaptr stops a take itself; shown above the summary.
    private var stopReason: String?

    /// Once a second while recording (disk checked every 10 s).
    private func checkRecordingHealth() {
        if Date().timeIntervalSince(lastDiskCheck) >= Self.diskCheckInterval,
           let dir = recordingURL?.deletingLastPathComponent(),
           let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
               .volumeAvailableCapacityForImportantUsage {
            lastDiskCheck = Date()
            if free < Self.stopBelowBytes {
                stopReason = String(format: "Stopped: only %.1f GB left on the save drive. The recording is saved.",
                                    Double(free) / 1e9)
                Task { await self.stopRecording() }
                return
            }
            if free < Self.warnBelowBytes, !warnedLowDisk {
                warnedLowDisk = true
                status = String(format: "Save drive is nearly full: %.1f GB left. Recording stops by itself at 1 GB.",
                                Double(free) / 1e9)
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if (thermal == .serious || thermal == .critical), !warnedHot {
            warnedHot = true
            status = "Your Mac is running hot. If frames start dropping, lower the resolution or encoding preset."
        }
    }

    /// Seconds between free-space checks (`-RecaptrUITestDiskCheckSeconds`
    /// shortens it in tests).
    private static var diskCheckInterval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "RecaptrUITestDiskCheckSeconds")
        return isUITesting && override > 0 ? override : 10
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
        // One stat() a second; the writer appends, so this tracks the
        // file as it grows.
        if let path = recordingURL?.path,
           let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
            recordingBytes = size.int64Value
        }
        let snapshot = recorder.stats()
        liveStats = snapshot
        checkRecordingHealth()

        // Surface a writer failure mid-recording so a long session
        // doesn't burn 20 minutes producing nothing.
        if snapshot.writerStatus == .failed {
            let msg = snapshot.writerErrorDescription ?? "writer failed"
            stopReason = "Writer failed mid-recording: \(msg)"
            Task { await self.stopRecording() }
        }
    }
}
