//
//  MainViewModel.swift
//  Recaptr
//
//  Main view model: owns the capture services, recorder, and audio mixer,
//  and holds the UI state.
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
/// Latest preview frame. Capture queues write it; screenshots read it.
/// `@unchecked Sendable` because the lock serializes all access.
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

    /// Save location: a security-scoped bookmark, with a sandbox fallback.
    @Published var recordingStorage = RecordingStorage()

    // Channel 1: source audio (capture card HDMI audio or the camera's mic),
    // auto-selected to match the video source.
    @Published var ch1DeviceID: String?
    @Published var ch1Gain: Double = 1.0
    @Published var ch1Enabled: Bool = true

    // Channel 2: commentary mic. Never auto-selected and never monitored
    // (hearing your own voice with latency is distracting).
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

    /// Series (game or show). Recordings go in a folder of this name,
    /// named "Series – Episode". Empty uses timestamp names.
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
    /// A Bool setting with a default. `bool(forKey:)` also reads "YES"/"NO"
    /// launch arguments, which `as? Bool` doesn't.
    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    /// Test runs share the app's settings, so test hooks don't save naming.
    private static let isUITesting = UserDefaults.standard.bool(forKey: "RecaptrUITesting")
    /// Name markers and blank episodes with Apple Intelligence.
    @Published var aiNamingEnabled: Bool =
        MainViewModel.bool("RecaptrAINaming", default: true) {
        didSet { UserDefaults.standard.set(aiNamingEnabled, forKey: "RecaptrAINaming") }
    }
    /// The most recent take's naming, so it can be renamed after the
    /// fact (Settings > Last recording > Rename).
    struct LastTake {
        var url: URL
        var series: String
        var markers: [(title: String, seconds: Double)]

        /// The episode part of the file name ("Ep 1 – Title"), or the
        /// whole name for takes without a series.
        var episode: String {
            let name = url.deletingPathExtension().lastPathComponent
            let prefix = series + SessionNaming.separator
            return !series.isEmpty && name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        }
    }
    @Published private(set) var lastTake: LastTake?

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

    /// Per-second readouts live in their own observable so only the views
    /// that show them redraw each tick.
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

    /// Screen Recording permission. A new grant usually only reaches
    /// `SCStream` after a relaunch.
    @Published var screenCapturePermissionGranted: Bool = false

    /// Recorder and mixer counters from the last take, kept apart so the
    /// file-probe status doesn't overwrite them.
    @Published var lastRecordingSummary: String?

    // Observers retained so they can be removed in deinit.
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Stops cleanly when the active device is unplugged.
    private var deviceDisconnectObserver: NSObjectProtocol?

    /// Refreshes the catalog on replug and switches to a capture card if
    /// nothing, or Continuity Camera, is selected.
    private var deviceConnectObserver: NSObjectProtocol?

    private var cancellables = Set<AnyCancellable>()

    let previewSinkLayer = SampleBufferPreviewLayer(frame: .zero)

    /// Latest preview frame for `captureScreenshot()`. Cleared on stop so a
    /// frame from the previous source can't be saved.
    let frameCache = PreviewFrameCache()

    /// Marker times in seconds. Cleared when a recording starts.
    @Published var markers: [TimeInterval] = []
    static let markerDebounce: TimeInterval = 1

    private var cameraService: CameraCaptureService?
    private var screenService: ScreenCaptureService?
    private let recorder = Recorder()
    /// System audio levels on the screen path without a mic, which skips
    /// the mixer.
    private let screenAudioLevels = LevelTracker()
    private let audioMixer: AudioMixer
    private var activeDims: CMVideoDimensions = .init(width: 0, height: 0)
    private var hasAudio = false  // Snapshot at startRecording, fixed until stopRecording

    /// True when a screen source's audio comes from the `SCStream` instead
    /// of the mixer.
    @Published var hasScreenAudio: Bool = false

    /// True while `startPreview` builds the session, so audio changes made
    /// during startup don't trigger a second restart.
    private var isStartingPreview = false

    private var recordingStartedAt: Date?
    /// ⌃⌥⌘B drops a marker from any app, registered only while
    /// recording so the combo is free the rest of the time.
    private var markerHotKey: GlobalHotKey?
    /// Held while recording so idle sleep can't cut a capture short. Also
    /// keeps the display awake: capture cards stall briefly when it sleeps.
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

        // Device and enable changes apply live while previewing, debounced so
        // a burst of changes restarts once.
        Publishers.Merge4(
            $ch1DeviceID.map { _ in () }, $ch1Enabled.map { _ in () },
            $ch2DeviceID.map { _ in () }, $ch2Enabled.map { _ in () }
        )
        .dropFirst(4)
        .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
        .sink { [weak self] in self?.applyAudioSelectionChange() }
        .store(in: &cancellables)

        // Gain is read on every tap callback, so no restart is needed.
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

        // The monitor plays one channel: the camera's source audio, or the mic
        // for screen and window captures (see `monitorChannelIndex`).
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

        // Stop cleanly if a permission is revoked mid-session instead of
        // recording silence or black frames.
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

        // The bundle ID is logged for checking `tccutil reset` targets.
        let bundleID = Bundle.main.bundleIdentifier ?? "<unknown>"
        let initialMic = AVCaptureDevice.authorizationStatus(for: .audio)
        let initialScreen = CGPreflightScreenCaptureAccess()
        screenCapturePermissionGranted = initialScreen
        print("Recaptr launched — bundle=\(bundleID), mic permission=\(Self.permissionLabel(initialMic)), screen recording=\(initialScreen ? "granted" : "not granted")")

        // Recheck permissions when the app comes to the front. `strongSelf` is
        // a let so the Task can capture it under Swift 6 concurrency.
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

        // Load the catalog before picking a startup source.
        Task {
            await self.refreshCatalog()
            // UI tests with a screen or window source: those can arrive after the
            // cameras, so wait rather than fall back to a camera.
            if Self.isUITesting, let want = UserDefaults.standard.string(forKey: "RecaptrUITestSource") {
                let kind: VideoSource.Kind = want == "display" ? .screenDisplay : .screenWindow
                for _ in 0..<20 where !self.catalog.videoSources.contains(where: { $0.kind == kind }) {
                    try? await Task.sleep(for: .milliseconds(250))
                    await self.refreshCatalog()
                }
            }
            await MainActor.run {
                self.autoSelectStartupSource()
                // -RecaptrUITestSeries / -RecaptrUITestEpisode <name>: preset the naming fields (not saved).
                if Self.isUITesting {
                    if let series = UserDefaults.standard.string(forKey: "RecaptrUITestSeries") { self.seriesName = series }
                    if let episode = UserDefaults.standard.string(forKey: "RecaptrUITestEpisode") { self.episodeName = episode }
                }
                // -RecaptrUITestMicInput <name>: bind the mic to the first input whose name contains <name>.
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
        // -RecaptrUITestProbeLatest YES: probe the newest recording, print what's in it, and quit.
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
        // Screen Recording is requested when a screen source is chosen, not at
        // launch, so camera-only users never see the prompt.
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

    /// Shows the microphone prompt if it hasn't been answered. Asking
    /// explicitly is more reliable than letting AVAudioEngine trigger it,
    /// which can fail silently and record silence.
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

    /// Rereads mic permission and updates the status line. Doesn't prompt.
    func recheckAudioPermission(reason: String) {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        let was = audioPermissionStatus
        audioPermissionStatus = current
        if current != was {
            print("recheckAudioPermission(\(reason)): \(Self.permissionLabel(was)) → \(Self.permissionLabel(current))")
        }

        switch current {
        case .authorized:
            // Clear only the denied message; don't overwrite other status.
            if status.hasPrefix("Microphone permission denied") {
                status = "Idle"
            }
        case .denied, .restricted:
            status = "Microphone permission denied — recordings will be silent. Open System Settings → Privacy & Security → Microphone to enable."
        case .notDetermined:
            Task { await self.requestAudioPermissionIfNeeded() }
        @unknown default:
            break
        }
    }

    /// Opens the Microphone privacy pane in System Settings.
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
        // Fall back to the privacy pane root.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen recording permission (TCC)

    /// Shows the Screen Recording prompt if needed. A grant usually only
    /// takes effect for `SCStream` after a relaunch, so the status says so.
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

    /// Called on switching to Window or Screen mode, so the permission is
    /// requested the first time it's needed.
    func screenModeSelected() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        requestScreenCapturePermissionIfNeeded()
    }

    /// Rereads Screen Recording permission. Doesn't prompt.
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

    /// Opens the Screen Recording privacy pane in System Settings.
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

    /// Cameras, displays, and windows for the source picker.
    var availableMainSources: [VideoSource] {
        catalog.videoSources
    }

    var availableAudioSources: [AudioSource] {
        catalog.audioSources
    }

    /// True when either channel has a device and is enabled.
    private var anyChannelArmed: Bool {
        (ch1Enabled && ch1DeviceID != nil) || (ch2Enabled && ch2DeviceID != nil)
    }

    // MARK: - Auto audio selection

    /// Picks Channel 1 to match the current video source.
    ///
    /// Cameras: the audio source whose name matches (exact, then either
    /// name containing the other). Capture cards expose a paired audio
    /// device with the same name. Screen and window sources leave Channel 1
    /// alone; their audio comes from the SCStream.
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
            // System audio comes from the SCStream, not Channel 1.
            break
        }
    }

    // MARK: - Fast audio level polling (for VU meter)
    //
    // Views poll these for the meters (about 30 Hz); `mixerStats` only
    // updates once a second. Snapshots are cheap reads.

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

    /// Screenshot errors, shown on the status line.
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

    /// Saves the latest preview frame as a PNG in the save folder and
    /// returns its URL. Uses the cached pixel buffer, so the image is at
    /// source resolution, not preview size.
    func captureScreenshot() async throws -> URL {
        guard let pixelBuffer = frameCache.latest() else {
            throw ScreenshotError.noFrame
        }

        // CIContext does the color conversion; the rest is cheap.
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

    /// Saves the last 15 seconds of the current screen source (instant
    /// replay), whether or not a recording is running.
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
            // The status line should describe this clip, not the last recording.
            lastRecordingSummary = nil
            status = "Replay saved → \(url.lastPathComponent)"
            await probeRecordedFile(url)
        } catch {
            status = "Replay failed: \(error.localizedDescription)"
        }
    }

    /// Adds a marker at the current recording time. No-op when not recording.
    func dropMarker() {
        guard isRecording else { return }
        // Exact time; recordingElapsed only ticks once a second.
        let t = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? recordingElapsed
        // One marker per second: extra presses from a mashed or held key are ignored.
        if let last = markers.last, t - last < Self.markerDebounce { return }
        markers.append(t)
        // Precise capture-clock time, for the .fcpxml.
        recorder.addMarker()
        status = String(format: "Marker dropped at %02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: - Auto startup source

    /// Picks a default source when none is selected: a capture card, then a
    /// non-Continuity camera, then any camera. Screens and windows are never
    /// auto-picked.
    func autoSelectStartupSource() {
        guard selectedMainSource == nil else { return }
        // -RecaptrUITestSource display|window:<name>: start on the first display, or the first window whose title contains <name>.
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
            autoSelectAudioForCurrentSource()
        }
    }

    // MARK: - Device disconnect handler

    /// Stops recording (keeping the partial file) and preview when the
    /// active camera is unplugged, then clears the selection.
    @MainActor
    private func handleDeviceDisconnect(_ note: Notification) async {
        guard let device = note.object as? AVCaptureDevice else { return }
        // Screen and window sources are handled by SCStream's onStreamStopped.
        guard let activeID = selectedMainSource?.cameraUniqueID,
              activeID == device.uniqueID else { return }

        let deviceName = device.localizedName
        let wasRecording = isRecording

        if wasRecording {
            // Finalizes the writer so the partial file is playable.
            await stopRecording()
        }
        if isPreviewing {
            stopPreview()
        }

        // Back to the "Select a source" hint until the user picks or replugs.
        selectedMainSource = nil

        status = wasRecording
            ? "Device disconnected: \(deviceName) — recording saved."
            : "Device disconnected: \(deviceName)"

        await catalog.refresh()

        // Unplugging a capture card also removes its audio device. Clear the
        // orphaned selection, which SwiftUI's Picker warns about.
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

    /// Refreshes the catalog when a device is plugged in. Switches to it
    /// only if nothing is selected, or if it's a capture card replacing a
    /// Continuity Camera. An explicit camera choice is kept.
    @MainActor
    private func handleDeviceConnect(_ note: Notification) async {
        guard let device = note.object as? AVCaptureDevice else { return }

        await catalog.refresh()

        // Catalog ids are "camera:<uniqueID>". If the refresh hasn't seen the
        // device yet, a later refresh will.
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
            // The camera notification arrives before CoreAudio registers the
            // paired audio device. Switching early leaves the recording video-only,
            // so wait up to 1.2 s.
            await waitForPairedAudio(matching: newSource, timeout: 1.2)

            if isPreviewing {
                stopPreview()
            }
            selectedMainSource = newSource
            status = "Capture card connected: \(newSource.name)"
            // Audio auto-select runs from ContentViewNext's onChange(of: selectedMainSource).
        }
    }

    // MARK: - Permission revocation handlers

    /// Stops preview and recording (keeping the file) when mic permission
    /// is revoked mid-session.
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

    /// Stops a screen or window capture when Screen Recording is revoked.
    /// Cameras don't need it.
    @MainActor
    private func handleScreenPermissionChange(_ granted: Bool) async {
        guard !granted else { return }
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

    /// Status line for a revoked permission.
    private func status_setRevoked(wasRecording: Bool, label: String, settingsHint: String) {
        if wasRecording {
            status = "\(label) permission revoked — recording stopped and saved. Re-enable in \(settingsHint), then restart preview."
        } else {
            status = "\(label) permission revoked — preview stopped. Re-enable in \(settingsHint), then restart."
        }
    }

    /// Polls until an audio device matching `source` appears or `timeout`
    /// passes. Uses the same name match as audio auto-select.
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
            // Responsive without hammering AVFoundation.
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Timed out. Carry on; the mixer logs the missing device and records
        // without that channel.
    }

    // MARK: - Preview

    func startPreview() async {
        isStartingPreview = true
        defer { isStartingPreview = false }
        stopPreview()

        // Clears a stale "denied" status if access was just granted.
        recheckAudioPermission(reason: "startPreview")

        guard let src = selectedMainSource else {
            status = "Select a source"
            return
        }

        // Catch missing Screen Recording permission here; SCStream's own error
        // is less readable.
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
                    // Keep the latest frame for screenshots (a pointer copy).
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
                // VideoSource only carries IDs, so fetch fresh SCDisplay objects.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == targetID }) else {
                    status = "Display \(targetID) no longer available — hit Refresh and reselect."
                    return
                }
                // Exclude Recaptr to avoid an infinite mirror. Excluding the app, not
                // its current windows, also covers windows opened later (the outline).
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
                // A single-window filter captures only that window; nothing to exclude.
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

            // Cameras use the mixer. Screen sources send system audio straight to
            // the recorder, or through the mixer when a mic is armed.
            let audioLabel: String
            switch src.kind {
            case .camera:
                hasScreenAudio = false
                // The mixer runs for the whole preview so meters work before recording.
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

    /// Builds a screen service with the callbacks shared by display and
    /// window capture. Preview stops if the stream dies (display unplugged,
    /// window closed, permission revoked).
    private func makeScreenService(audioViaMixer: Bool) -> ScreenCaptureService {
        let svc = ScreenCaptureService()
        svc.instantReplay = instantReplay
        svc.onRecordBuffer = { [weak self] sb in
            // Keep the latest frame for screenshots.
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                self?.frameCache.store(pb)
            }
            self?.recorder.appendVideo(sb)
        }
        // Without a mic, system audio goes straight to the recorder with its
        // own timestamps (tightest A/V sync). With a mic, it goes through the
        // mixer's System channel.
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
        // The mixer lives as long as the preview, not the recording.
        if audioMixer.running { audioMixer.stop() }
        stopStatsTimer()
        // Reset so the meters go dark instead of holding the last value.
        mixerStats = AudioMixerStats()

        cameraService?.stop()
        cameraService = nil
        lowLightNoiseReductionSupported = false

        // `stop()` is async; nil the reference first so a new preview doesn't
        // see the old service.
        if let svc = screenService {
            screenService = nil
            Task { await svc.stop() }
        }
        hasScreenAudio = false
        replayAvailable = false
        captureOutline.hide()

        previewSinkLayer.flush()
        // Drop the cached frame so it can't be saved after preview ends.
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

        markers = []

        // Screen sources record the SCStream audio; cameras use the mixer,
        // already running from preview.
        hasAudio = hasScreenAudio || (audioMixer.running && audioMixer.hasAnyEnabledChannel)

        // Resolved per recording so a newly attached drive works without a
        // restart.
        let saveDir: URL
        do {
            saveDir = try recordingStorage.resolveSaveDirectory()
        } catch {
            status = "Save directory error: \(error.localizedDescription)"
            return
        }

        // Refuse to start under 2 GB free (4K60 runs about 400 MB/min) rather
        // than fail minutes in.
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
            // Some volumes (network mounts) don't report capacity. Don't block on it.
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
            // mixerStats aren't reset so the meters stay continuous.
            liveStats = RecorderStats()
            lastRecordedFile = nil
            lastFileProbeSummary = nil
            let audioLabel = hasAudio ? " + audio (mixer)" : " (video only — no audio armed)"
            status = "Recording → \(url.lastPathComponent)\(audioLabel)"
            // The stats timer is already running from preview.
        } catch {
            status = "Recorder error: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        // Only the recorder stops; the mixer and stats timer keep running.
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

        // Snapshot after stop() so the summary has the final numbers.
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


        // Probe the file's tracks (catches a take saved without audio), then
        // name and file it.
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
        lastTake = LastTake(url: finalURL, series: series, markers: markers)
    }

    /// Rename the last take's episode and markers: moves the .mov (and
    /// replaces its .fcpxml) to the new name in the same folder, never
    /// over an existing file, and rewrites the markers.
    func renameLastTake(episode: String, markerTitles: [String]) async throws {
        guard var take = lastTake else { return }
        let folder = take.url.deletingLastPathComponent()
        let cleanEpisode = SessionNaming.sanitize(episode)
        let base = take.series.isEmpty ? cleanEpisode : SessionNaming.baseName(series: take.series, episode: cleanEpisode)
        guard !cleanEpisode.isEmpty else { return }

        var target = take.url
        if base != take.url.deletingPathExtension().lastPathComponent {
            target = SessionNaming.uniqueURL(in: folder, base: base, ext: "mov")
            try FileManager.default.moveItem(at: take.url, to: target)
            // The old .fcpxml points at the old name; it's rewritten below.
            try? FileManager.default.removeItem(at: take.url.deletingPathExtension().appendingPathExtension("fcpxml"))
        }
        for index in take.markers.indices where index < markerTitles.count {
            let title = markerTitles[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { take.markers[index].title = title }
        }
        take.url = target
        lastRecordedFile = target
        lastTake = take
        await writeFinalCutMarkers(for: target, markers: take.markers,
                                   eventName: take.series.isEmpty ? nil : take.series)
        status = "Renamed to \(target.lastPathComponent)"
    }

    /// Counters from the final stats snapshots, so the cause of a silent
    /// take shows without the console.
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
                // UI tests print the .fcpxml.
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

    /// Opens the saved .mov and reports what's in it, so a missing audio
    /// track shows on the status line.
    private func probeRecordedFile(_ url: URL) async {
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
            // Status shows what was recorded, then what's in the file (also the
            // Diagnostics text in Settings).
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

    /// `-RecaptrUITestAutoRecord <seconds>`: record once, 3 s after preview
    /// starts, then quit after the file probe prints.
    private var uiTestAutoRecordDone = false
    private func scheduleUITestAutoRecordIfRequested() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "RecaptrUITesting"), !uiTestAutoRecordDone else { return }
        let seconds = d.double(forKey: "RecaptrUITestAutoRecord")
        guard seconds > 0 else { return }
        uiTestAutoRecordDone = true
        // -RecaptrUITestResetNaming YES: clear the saved series and history.
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
            // Levels a few seconds in show the channels carry sound, not silence.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                let fmt: ((rms: Float, peak: Float)?) -> String = { l in l.map { String(format: "%.1f dBFS peak", $0.peak) } ?? "none" }
                print("RecaptrUITest: levels source=\(fmt(self.channelLevels(0))) mic=\(fmt(self.channelLevels(1)))")
            }
            // Window layers, for the outline check.
            let mine = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
                .compactMap { $0[kCGWindowLayer as String] as? Int }
            print("RecaptrUITest: own window layers \(mine.sorted())")
            // The outline: a display-sized Recaptr window at status-bar level (the
            // menu bar item shares that level, so layer alone proves nothing).
            let outlines = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 25
                    && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 800 }
            print("RecaptrUITest: capture outline windows \(outlines.count)")
            // -RecaptrUITestMonitor YES: monitor the source during the take (latency tests).
            if d.bool(forKey: "RecaptrUITestMonitor") {
                // -RecaptrUITestMonitorVolume <n>: monitor volume (0 avoids speaker feedback).
                if let v = d.object(forKey: "RecaptrUITestMonitorVolume") as? NSNumber { monitorVolume = v.doubleValue }
                else if let v = d.string(forKey: "RecaptrUITestMonitorVolume"), let n = Double(v) { monitorVolume = n }
                monitorEnabled = true
            }
            #if DEBUG
            // -RecaptrUITestMeasureMonitorLag YES: log monitor buffer fill every 10 s, then measure lag.
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
            // -RecaptrUITestAutoMarkers <n>: drop n markers spread evenly through the take.
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

    /// Applies a device or enable change while previewing. Cameras restart
    /// only the mixer. Screen sources route system audio differently with
    /// and without a mic, so arming or disarming the mic restarts preview.
    /// Ignored while recording.
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

    /// Copies UI state into the mixer's channels before `start()`. Screen
    /// sources mix the System channel with the mic; channel 1 stays off
    /// because its device belongs to the camera path.
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
        // Screen captures monitor only the mic: system audio already plays
        // through the speakers.
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
        // `strongSelf` is a let so the Task can capture it under Swift 6 concurrency.
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
        // -RecaptrUITestStopBelowGB <n>: raise the threshold so tests can trigger the stop.
        let override = UserDefaults.standard.double(forKey: "RecaptrUITestStopBelowGB")
        return isUITesting && override > 0 ? Int64(override * 1e9) : 1_000_000_000
    }
    static let warnBelowBytes: Int64 = 5_000_000_000
    private var lastDiskCheck = Date.distantPast
    private var warnedLowDisk = false
    private var warnedHot = false
    /// Set when Recaptr stops a take itself; shown above the summary.
    private var stopReason: String?

    /// Runs once a second while recording; disk is checked every 10 s.
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

    /// Seconds between free-space checks. `-RecaptrUITestDiskCheckSeconds <n>`
    /// overrides it in tests.
    private static var diskCheckInterval: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "RecaptrUITestDiskCheckSeconds")
        return isUITesting && override > 0 ? override : 10
    }

    private func stopStatsTimer() {
        recorderStatsTimer?.invalidate()
        recorderStatsTimer = nil
    }

    private func tickStats() {
        // Mixer stats update during preview and recording; recorder stats and
        // the timer only while recording.
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

        // Stop on a writer failure so a long take doesn't record nothing.
        if snapshot.writerStatus == .failed {
            let msg = snapshot.writerErrorDescription ?? "writer failed"
            stopReason = "Writer failed mid-recording: \(msg)"
            Task { await self.stopRecording() }
        }
    }
}
