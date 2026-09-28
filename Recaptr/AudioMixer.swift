//
//  AudioMixer.swift
//  Recaptr
//
//  N-channel audio capture, per-channel gain, single mixed AAC track
//  out. Currently exposed to the UI as one channel + a live monitor;
//  the N-channel architecture stays in place so multi-source support
//  (e.g. via an aggregate device) can land later without rewriting.
//
//  Architecture
//  ─────────────
//  Each `AudioInputChannel` owns its own `AVAudioEngine`, bound to a
//  specific physical input device via Core Audio's
//  `kAudioOutputUnitProperty_CurrentDevice`. The engine's input node
//  has a tap installed at the device's native format. The tap
//  callback runs the buffer through a cached `AVAudioConverter` into
//  the canonical mixer format (48 kHz / Stereo / Float32 /
//  interleaved), applies the channel gain in place, computes VU
//  meters, and pushes the converted buffer onto the channel's pending
//  queue under a lock.
//
//  `AudioMixer` runs a `DispatchSourceTimer` at ~21.3 ms cadence
//  (1024 frames @ 48 kHz). Each tick pulls 1024 frames from each
//  enabled channel, sums them into a working buffer (zero-filling
//  where a channel is starved), wraps the sum in a `CMSampleBuffer`
//  with a monotonically-advancing PTS, and hands it to
//  `onMixedSampleBuffer` (which feeds `Recorder.appendAudio`).
//
//  Mixer PTS is anchored to the host time clock
//  (`CMClockGetHostTimeClock`) at `start()`, then advanced by
//  `sampleClock / sampleRate`, so audio PTSes share the time domain
//  with `AVCaptureSession`'s video PTSes. Putting audio in a
//  different domain (e.g. starting at zero) causes every audio
//  sample to land before the session anchor and be dropped.
//
//  Live monitor (foldback)
//  ───────────────────────
//  An output-only `AVAudioEngine` plays each post-gain buffer back to
//  the system default output device. Output-only engines avoid the
//  multi-input HAL conflict that would otherwise prevent capturing
//  while monitoring. `AVAudioEngine.outputNode` binds to whichever
//  device was the system default at engine-start time and does NOT
//  follow later Sound-settings changes, so the monitor engine is
//  rebuilt fresh on every toggle-on (see `buildMonitorEngine`).
//
//  Pre-record lock
//  ───────────────
//  Channel configuration (device, gain, enabled) is set BEFORE
//  `start()`. `MainViewModel` brackets the mixer's `start()` /
//  `stop()` calls around the preview / recording lifecycle, and the
//  UI disables the channel controls while `isRecording` is true.
//
//  Limitations
//  ───────────
//   • No system-loopback capture for game audio on camera sources
//     (a virtual audio device like BlackHole is required — Apple does
//     not expose loopback of arbitrary audio outputs). Screen sources
//     get system audio through `SCStream` instead.
//   • macOS HAL refuses two simultaneous `AVAudioEngine` input
//     bindings to different physical devices; multi-channel capture
//     requires a Core Audio aggregate device. `start()` already
//     degrades gracefully when a channel can't start, but UI today
//     only surfaces one channel.
//   • Channel alignment is drop-or-zero-fill, not phase-accurate
//     cross-device sync.
//

import Foundation
import AVFoundation
import Accelerate
import CoreAudio
import CoreMedia

// MARK: - Stats (UI surface)

struct AudioInputChannelStats: Equatable {
    var label: String = ""
    var deviceLabel: String = ""
    var enabled: Bool = false
    var running: Bool = false
    var gain: Float = 1.0
    var nativeSampleRate: Double = 0
    var nativeChannels: Int = 0
    var convertedFramesPushed: Int = 0
    var framesPulledByMixer: Int = 0
    var zeroFillEvents: Int = 0
    /// Frames dropped to keep this channel's backlog bounded (device
    /// clock running ahead of the mixer). Zero in a normal session.
    var trimmedFrames: Int = 0
    /// Clock-drift corrections: single frames dropped (device fast)
    /// and repeated (device slow) to hold the backlog steady.
    var driftDrops: Int = 0
    var driftRepeats: Int = 0
    /// Measured device clock error versus the host clock, in parts per
    /// million (positive = device fast). Nil until measured.
    var driftPPM: Double?
    /// Automatic restarts after a stall or audio hardware change.
    var recoveries: Int = 0
    var lastRecoveryReason: String?
    var lastError: String?
    /// RMS over the last converted buffer, in dBFS (-∞ … 0).
    /// Smoothed with a one-pole low-pass for a stable VU display.
    var rmsDbfs: Float = -120.0
    /// Peak sample magnitude over the last converted buffer, in dBFS.
    var peakDbfs: Float = -120.0
}

struct AudioMixerStats: Equatable {
    var running: Bool = false
    var mixedFramesEmitted: Int = 0
    var ticks: Int = 0
    /// Chunks emitted late to catch up with the clock (system busy).
    var catchUpChunks: Int = 0
    var channels: [AudioInputChannelStats] = []
}

// MARK: - Constants

/// Canonical mixer format: 48 kHz / Stereo / Float32 / interleaved.
/// Interleaved makes CMSampleBuffer construction straightforward
/// (one CMBlockBuffer wrapping the whole frame range).
nonisolated private let kMixerSampleRate: Double = 48_000
nonisolated private let kMixerChannels: AVAudioChannelCount = 2
nonisolated private let kMixerChunkFrames: AVAudioFrameCount = 1024

private func makeMixerFormat() -> AVAudioFormat {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: kMixerSampleRate,
        channels: kMixerChannels,
        interleaved: true
    )!
}

// MARK: - Drift pacing

/// Spreads clock-drift corrections evenly: given a device's error in
/// ppm, says for each pull whether to drop a frame (+1), repeat one
/// (-1), or neither (0), so that over time exactly `ppm` millionths of
/// the frames are corrected, never more than one per pull.
nonisolated struct DriftPacer {
    private var accumulator: Double = 0

    mutating func next(frames: Int, ppm: Double) -> Int {
        accumulator += Double(frames) * ppm / 1_000_000
        if accumulator >= 1 { accumulator -= 1; return 1 }
        if accumulator <= -1 { accumulator += 1; return -1 }
        return 0
    }
}

// MARK: - AudioInputChannel

/// One input source with its own AVAudioEngine bound to a specific
/// physical input device.
nonisolated final class AudioInputChannel: @unchecked Sendable {

    let label: String
    private let outputFormat: AVAudioFormat
    /// Non-interleaved standard format used for the monitor engine's
    /// player → mixer connection. `AVAudioEngine`'s mixer nodes reject
    /// interleaved formats on bus connections, and `outputFormat`
    /// (used for `CMSampleBuffer` construction) is interleaved — so a
    /// separate format is required for the monitor side.
    private let monitorFormat: AVAudioFormat

    // Configuration — set by UI before start(); locked while running.
    var deviceUniqueID: String?
    var deviceLabel: String = "—"
    var gain: Float = 1.0 {
        didSet { monitorRing.gain = gain }
    }
    var enabled: Bool = true

    /// Low-latency monitor feed (see MonitorRing). Written by
    /// `sinkNode` on the capture engine, read by the monitor engine's
    /// source node. Nil sink means the native format didn't fit (not
    /// 48 kHz Float32, or more than two channels) and monitoring falls
    /// back to scheduling tap buffers on a player node.
    let monitorRing = MonitorRing()
    private var sinkNode: AVAudioSinkNode?
    /// True when the current monitor engine plays from `monitorRing`.
    private var monitorUsesRing = false

    // Internal state.
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var tapInstalled = false
    private(set) var running = false

    // Pending converted buffers + counters. Protected by lock.
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrameOffset: AVAudioFrameCount = 0  // index into pending.first
    private var pendingFrameCount: AVAudioFrameCount = 0
    /// Backlog cap. Taps deliver ~100 ms per callback, so a healthy
    /// backlog peaks a little above that. Past `maxPendingFrames`
    /// (250 ms) the oldest audio is dropped back to
    /// `trimTargetFrames`, so a device clock running ahead of the
    /// mixer can't push this source further and further out of sync.
    private let maxPendingFrames: AVAudioFrameCount = 12_000
    private let trimTargetFrames: AVAudioFrameCount = 6_000
    private var trimmedFrames: Int = 0

    /// Clock-drift compensation (tap channels). Each capture device
    /// runs on its own clock and the mixer pulls at the host clock, so
    /// a device even slightly fast piles up backlog and its audio falls
    /// steadily behind; a slow one does the opposite. Measured
    /// 2026-09-27: the Yeti mic slid 20 ms behind the Elgato's game
    /// audio every 10 minutes (~33 ppm), about 120 ms over an hour.
    ///
    /// The device's true rate comes from the tap timestamps: device
    /// sample time against host time since the first callback, exact
    /// to a few ppm after ~20 s. The pull then drops one frame (device
    /// fast) or repeats one (device slow) at exactly that rate, e.g.
    /// ~1.6 frames a second at 33 ppm, which is inaudible.
    ///
    /// Not measured from the backlog: tried first, and the mixer timer
    /// running late under encoding load reads as extra backlog, so it
    /// dropped a frame on every pull and caused underruns (10-minute
    /// test, 2026-09-27).
    private var driftFirstStamp: (sample: Double, host: Double)?
    private var driftPPMValue: Double?
    private var driftPacer = DriftPacer()
    private var driftDrops = 0
    private var driftRepeats = 0
    #if DEBUG
    /// UI tests: average backlog per pull since the last read, to
    /// check that correction holds it flat.
    private var backlogSum: Double = 0
    private var backlogSamples = 0
    func takeBacklogAverage() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard backlogSamples > 0 else { return nil }
        let average = backlogSum / Double(backlogSamples)
        backlogSum = 0
        backlogSamples = 0
        return average
    }
    /// `-RecaptrUITestNoDriftCorrection YES` measures but doesn't correct.
    static let driftCorrectionDisabledForTesting =
        UserDefaults.standard.bool(forKey: "RecaptrUITesting")
        && UserDefaults.standard.bool(forKey: "RecaptrUITestNoDriftCorrection")
    #endif

    /// Seconds of timestamps needed before correcting.
    private static let driftMinSeconds = 20.0
    /// Ignore readings beyond this; a real crystal is within ~100 ppm,
    /// so anything larger is a timestamp glitch.
    private static let driftMaxPPM = 500.0

    private func resetDriftLocked() {
        driftFirstStamp = nil
        driftPPMValue = nil
        driftPacer = DriftPacer()
        externalFramesSinceFirst = 0
    }

    /// External channels: frames delivered so far, for the rate.
    private var externalFramesSinceFirst: Double = 0

    /// Update the rate estimate from an external buffer's host-time
    /// stamp. Same measurement as `noteTapTimeLocked`, with the sample
    /// count kept here. Lock held.
    private func noteExternalTimeLocked(ptsSeconds: Double, frames: Int, rate: Double) {
        guard rate > 0 else { return }
        guard let first = driftFirstStamp else {
            driftFirstStamp = (0, ptsSeconds)
            externalFramesSinceFirst = Double(frames)
            return
        }
        let elapsed = ptsSeconds - first.host
        if elapsed >= Self.driftMinSeconds {
            let ppm = (externalFramesSinceFirst / elapsed / rate - 1) * 1_000_000
            driftPPMValue = abs(ppm) <= Self.driftMaxPPM ? ppm : nil
        }
        externalFramesSinceFirst += Double(frames)
    }

    /// Update the device-rate estimate from a tap timestamp. Lock held.
    private func noteTapTimeLocked(_ when: AVAudioTime, rate: Double) {
        guard when.isSampleTimeValid, when.isHostTimeValid, rate > 0 else { return }
        let sample = Double(when.sampleTime)
        let host = AVAudioTime.seconds(forHostTime: when.hostTime)
        guard let first = driftFirstStamp else {
            driftFirstStamp = (sample, host)
            return
        }
        let elapsed = host - first.host
        guard elapsed >= Self.driftMinSeconds else { return }
        let ppm = ((sample - first.sample) / elapsed / rate - 1) * 1_000_000
        driftPPMValue = abs(ppm) <= Self.driftMaxPPM ? ppm : nil
    }

    /// Jitter buffer for externally fed channels. SCStream delivers
    /// system audio in small, irregular chunks, so pulling from the
    /// first frame starves the queue and each underrun inserts a
    /// sliver of silence (audible crackle). An external channel waits
    /// until `primeFrames` (~43 ms) are queued before feeding the mix,
    /// and re-primes after an underrun. Tap channels deliver ~100 ms
    /// at a time and don't need it, so they keep their timing.
    private var primeFrames: AVAudioFrameCount { isExternal ? 2_048 : 0 }
    private var primed = false
    private(set) var convertedFramesPushed: Int = 0
    private(set) var framesPulledByMixer: Int = 0
    private(set) var zeroFillEvents: Int = 0
    private(set) var lastError: String?

    // VU meter — smoothed RMS / peak in dBFS, updated each tap
    // callback. Read by `snapshot()` under lock.
    private var smoothedRmsDbfs: Float = -120.0
    private var lastPeakDbfs: Float = -120.0

    /// Tap-firing diagnostic. Logged on the first call and every
    /// 500th call (about once per ~10 s at 48 kHz / 1024 frames per
    /// tap). A plateauing counter is a strong signal that the tap
    /// stalled.
    private var tapCallCount: Int = 0
    /// Set by the first tap callback after `start()`. Guarded by `lock`.
    private var deliveredSinceStart = false

    // Live audio monitoring. A separate output-only `AVAudioEngine`
    // plays each post-gain buffer back to the system default output
    // device. Output-only engines avoid the multi-input HAL conflict
    // that prevents capturing while monitoring. Latency is roughly
    // tap-buffer (~21–100 ms) + `AVAudioPlayerNode` scheduling
    // (~10–20 ms).
    //
    // These are `var` because `AVAudioEngine.outputNode` binds to the
    // system default output at engine-start time and does NOT follow
    // later changes in Sound settings. `startMonitorIfNeeded()`
    // rebuilds the engine on every toggle-on so it always binds to
    // the user's *current* output choice.
    private var monitorEngine = AVAudioEngine()
    private var monitorPlayerNode = AVAudioPlayerNode()
    private var monitorRunning = false
    /// Settable from MainViewModel; checked in handleTap before
    /// scheduling output. Toggling this on after start() requires
    /// a separate startMonitorIfNeeded() call to fire up the engine.
    var monitorEnabled: Bool = false
    /// 0…1.5 — drives monitorEngine.mainMixerNode.outputVolume.
    /// 1.5 ceiling matches the channel's input gain ceiling so the
    /// UI slider semantics are consistent.
    var monitorVolume: Float = 1.0 {
        didSet { monitorEngine.mainMixerNode.outputVolume = monitorVolume }
    }

    /// True for a channel fed from outside (SCStream system audio via
    /// `pushExternal`) instead of its own input engine.
    let isExternal: Bool

    /// Armed channels are started by the mixer: enabled, and either
    /// externally fed or bound to a device.
    var isArmed: Bool { enabled && (isExternal || deviceUniqueID != nil) }

    init(label: String, outputFormat: AVAudioFormat, isExternal: Bool = false) {
        self.label = label
        self.outputFormat = outputFormat
        self.isExternal = isExternal
        // `standardFormatWithSampleRate:` produces a non-interleaved
        // Float32 format that `AVAudioEngine`'s mixer nodes accept on
        // bus connections. Each `outBuf` is de-interleaved into a
        // buffer of this format before being scheduled on the monitor
        // player node (see `handleTap`).
        self.monitorFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputFormat.sampleRate,
            channels: outputFormat.channelCount
        ) ?? outputFormat

        // Initial wire of the monitor graph via the same builder
        // `startMonitorIfNeeded()` uses, so the (re)build path is the
        // single source of truth. The engine constructed here is
        // effectively throwaway — it gets replaced on the first
        // toggle-on so the `outputNode` binds to the *then-current*
        // default output device.
        buildMonitorEngine()

        // macOS stops a running engine when the audio hardware setup
        // changes (for example the default output switching from
        // AirPods to speakers). Without handling this, capture dies
        // silently and the mixer records zeros. The mixer restarts
        // the channel when this fires.
        if !isExternal {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // The notice also fires for changes the engine rides
                // through (for example another engine starting). Only
                // a stopped engine needs recovering.
                guard !self.engine.isRunning else {
                    print("AudioInputChannel[\(self.label)]: audio configuration changed, engine still running")
                    return
                }
                print("AudioInputChannel[\(self.label)]: audio hardware configuration changed, engine stopped")
                self.onConfigurationChange?(self)
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let monitorConfigObserver { NotificationCenter.default.removeObserver(monitorConfigObserver) }
    }

    /// Set by the mixer. Called on the main queue when macOS reports
    /// an audio hardware change for this channel's engine.
    var onConfigurationChange: ((AudioInputChannel) -> Void)?
    private var configObserver: NSObjectProtocol?

    /// Frames captured so far (monotonic). The runtime watchdog
    /// compares successive readings to spot a stalled channel.
    var pushedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return convertedFramesPushed
    }

    /// Recoveries after a stall or hardware change this session.
    private(set) var recoveryCount = 0
    private(set) var lastRecoveryReason: String?
    func noteRecovery(reason: String) {
        recoveryCount += 1
        lastRecoveryReason = reason
    }

    /// UI tests only: while set, `start()` fails as if the device had
    /// vanished (an HDMI mode change resetting a capture card's audio).
    var unavailableUntilForTesting: Date?

    /// UI tests only: stop the engine the way macOS does on a hardware
    /// change, optionally without the notification (a silent stall).
    func simulateEngineStopForTesting(notify: Bool) {
        guard !isExternal, running else { return }
        engine.stop()
        if notify {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        }
    }

    /// (Re)build the monitor engine + player node from scratch and
    /// re-wire the graph. `AVAudioEngine.outputNode` binds to whichever
    /// device is the system default output at engine-start time, and
    /// does NOT follow later Sound-settings changes — so
    /// `startMonitorIfNeeded()` calls this on every toggle-on,
    /// throwing away the previous engine. The fresh engine binds to
    /// whatever the user's current default output is (speakers,
    /// headphones, AirPods, an HDMI device, etc.).
    ///
    /// A permanent fix would observe
    /// `kAudioHardwarePropertyDefaultOutputDevice` changes and rebuild
    /// transparently; that's deferred.
    private func buildMonitorEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // Play straight from the ring when the capture engine feeds
        // it; otherwise schedule tap buffers on the player.
        let useRing = sinkNode != nil && monitorFormat.channelCount == 2
        do {
            if useRing {
                let ring = monitorRing
                let source = AVAudioSourceNode(format: monitorFormat) { isSilence, _, frameCount, outputData in
                    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
                    guard buffers.count >= 2,
                          let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                          let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                        isSilence.pointee = true
                        return noErr
                    }
                    if !ring.read(left: l, right: r, frames: Int(frameCount)) {
                        isSilence.pointee = true
                    }
                    return noErr
                }
                engine.attach(source)
                try engine.connectNode(source, to: engine.mainMixerNode, format: monitorFormat)
            } else {
                engine.attach(player)
                try engine.connectNode(player, to: engine.mainMixerNode, format: monitorFormat)
            }
        } catch {
            print("AudioInputChannel[\(label)]: monitor connect failed: \(error.localizedDescription)")
        }
        self.monitorUsesRing = useRing
        engine.mainMixerNode.outputVolume = monitorVolume
        self.monitorEngine = engine
        self.monitorPlayerNode = player

        // Output device changed (AirPods to speakers, etc.): macOS
        // stops this engine. Rebuild it so monitoring continues on the
        // new default output.
        if let monitorConfigObserver { NotificationCenter.default.removeObserver(monitorConfigObserver) }
        monitorConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.monitorRunning else { return }
            print("AudioInputChannel[\(self.label)]: output changed, rebuilding monitor")
            self.stopMonitor()
            self.startMonitorIfNeeded()
        }
    }
    private var monitorConfigObserver: NSObjectProtocol?

    /// Monitor audio scheduled but not yet played, and chunks skipped
    /// to keep the monitor from drifting behind. Guarded by monitorLock
    /// (completion handlers run on an audio thread).
    private let monitorLock = NSLock()
    private var monitorQueuedFrames = 0
    private(set) var monitorSkips = 0

    /// Start the monitor engine if `monitorEnabled` is set. Called by
    /// `AudioMixer` after a successful capture engine start.
    /// Idempotent — safe to call when already running.
    ///
    /// Each toggle-on rebuilds the engine via `buildMonitorEngine()`
    /// so the `outputNode` re-binds to the current system default
    /// output device. Without this, the engine stays bound to whatever
    /// was default at the previous start, producing silent monitor
    /// playback on the wrong device if the user switched outputs.
    func startMonitorIfNeeded() {
        guard monitorEnabled, !monitorRunning else { return }
        buildMonitorEngine()
        do {
            monitorEngine.prepare()
            try monitorEngine.start()
            if !monitorUsesRing { try monitorPlayerNode.playAudio() }
            monitorRunning = true
            let outFormat = monitorEngine.outputNode.outputFormat(forBus: 0)
            print("AudioInputChannel[\(label)]: monitor engine started (\(monitorUsesRing ? "low-latency ring" : "player")) — outputNode format=\(outFormat)")
        } catch {
            print("AudioInputChannel[\(label)]: monitor engine start failed: \(error.localizedDescription)")
        }
    }

    /// Stop the monitor engine.
    func stopMonitor() {
        monitorLock.lock(); monitorQueuedFrames = 0; monitorLock.unlock()
        guard monitorRunning else { return }
        if monitorUsesRing {
            print("AudioInputChannel[\(label)]: monitor stopped, ring skips=\(monitorRing.skips) underruns=\(monitorRing.underruns)")
        } else {
            monitorPlayerNode.stop()
        }
        monitorEngine.stop()
        monitorRunning = false
    }

    /// Toggle the monitor on or off without restarting capture.
    /// Called from `MainViewModel` via Combine when the UI toggle
    /// changes.
    func setMonitor(enabled: Bool) {
        monitorEnabled = enabled
        if enabled {
            startMonitorIfNeeded()
        } else {
            stopMonitor()
        }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }
        if let until = unavailableUntilForTesting, Date() < until {
            throw CaptureError.configurationFailed("\(label): device unavailable (test)")
        }
        if isExternal {
            // No engine: buffers arrive through `pushExternal`. The
            // converter is built from the first buffer's format.
            converter = nil
            nativeFormat = nil
            running = true
            tapCallCount = 0
            lock.lock(); deliveredSinceStart = false; lock.unlock()
            return
        }
        guard let deviceUID = deviceUniqueID else {
            throw CaptureError.configurationFailed("\(label): no device selected")
        }

        // 1. Find Core Audio device ID for the AVCaptureDevice uniqueID.
        let coreAudioID = try Self.audioDeviceID(forUID: deviceUID)
        print("AudioInputChannel[\(label)]: resolved UID '\(deviceUID)' → CoreAudio device \(coreAudioID)")

        // 2. Bind the engine's input audio unit to that device.
        try Self.setEngineInputDevice(engine: engine, deviceID: coreAudioID)
        // Read it back. If the engine quietly fell back to the default
        // input, surface that — otherwise we'd capture from the wrong
        // device with no warning.
        if let actualID = try? Self.currentEngineInputDeviceID(engine: engine), actualID != coreAudioID {
            print("AudioInputChannel[\(label)]: WARNING device mismatch after set — wanted \(coreAudioID), got \(actualID)")
        }

        // 3. Inspect native format on the input bus.
        let format = engine.inputNode.inputFormat(forBus: 0)
        print("AudioInputChannel[\(label)]: native format \(format.sampleRate)Hz × \(format.channelCount)ch (\(format.commonFormat.rawValue))")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.configurationFailed("\(label): native format has zero rate/channels (mic permission denied?)")
        }
        nativeFormat = format

        // 4. Build a converter from native → canonical mixer format.
        guard let conv = AVAudioConverter(from: format, to: outputFormat) else {
            throw CaptureError.configurationFailed("\(label): could not build converter \(format) → \(outputFormat)")
        }
        converter = conv

        // 5. Install tap. Deliberately the pre-27 `installTap`, even
        // though Swift marks it deprecated at macOS 27. Tested
        // 2026-09-26 with an Elgato 4K X: the replacement
        // `installAudioTap` delivered audio on a fresh engine but no
        // audio at all after a channel stop/start (source switch),
        // leaving recordings with a silent track. Its documented
        // minimum buffer is also 100 ms versus 1024 frames (~21 ms)
        // here, which would add monitor latency.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in
            self?.handleTap(buf, when: when)
        }
        tapInstalled = true

        // 5b. Low-latency monitor feed: a sink node on the input
        // receives each I/O cycle (~10 ms) and copies it into the
        // ring. The tap above keeps feeding the recording unchanged.
        attachMonitorSink(format: format)

        // 6. Start.
        engine.prepare()
        try engine.start()
        running = true
        tapCallCount = 0
        // A successful start clears any error from an earlier attempt.
        lock.lock(); deliveredSinceStart = false; lastError = nil; lock.unlock()
        print("AudioInputChannel[\(label)]: engine started")
    }

    /// Connect the input to a sink node that copies each I/O cycle
    /// into `monitorRing`. Only for 48 kHz Float32 planar input with
    /// one or two channels (the ring does no resampling); anything
    /// else leaves `sinkNode` nil and the monitor uses the tap path.
    private func attachMonitorSink(format: AVAudioFormat) {
        // UI tests: `-RecaptrUITestMonitorTapPath YES` keeps the old
        // path, for latency comparisons.
        let d = UserDefaults.standard
        if d.bool(forKey: "RecaptrUITesting"), d.bool(forKey: "RecaptrUITestMonitorTapPath") { return }
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.sampleRate == monitorFormat.sampleRate,
              (1...2).contains(format.channelCount) else {
            print("AudioInputChannel[\(label)]: monitor uses tap path (format \(format))")
            return
        }
        let ring = monitorRing
        let sink = AVAudioSinkNode { _, frameCount, inputData in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count >= 1,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            ring.write(left: l, right: r.map { UnsafePointer($0) }, frames: Int(frameCount))
            return noErr
        }
        engine.attach(sink)
        do {
            try engine.connectNode(engine.inputNode, to: sink, format: format)
        } catch {
            engine.detach(sink)
            print("AudioInputChannel[\(label)]: monitor sink not connected (\(error.localizedDescription)); using tap path")
            return
        }
        sinkNode = sink
    }

    /// Feed one externally captured buffer (SCStream system audio)
    /// through the same convert, gain, meter, and queue path a tap
    /// uses. Called on SCStream's audio queue.
    func pushExternal(_ sampleBuffer: CMSampleBuffer) {
        guard isExternal, running else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = AVAudioFormat(formatDescription: desc) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        ) == noErr else { return }

        // Drift: SCStream stamps buffers in host time, so frames
        // delivered against those stamps give the system audio's rate
        // the same way tap timestamps do for a device.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            lock.lock()
            noteExternalTimeLocked(ptsSeconds: pts.seconds, frames: frames, rate: format.sampleRate)
            lock.unlock()
        }

        if nativeFormat != format {
            guard let conv = AVAudioConverter(from: format, to: outputFormat) else {
                recordStartFailure("\(label): could not build converter \(format) → \(outputFormat)")
                return
            }
            nativeFormat = format
            converter = conv
        }
        handleTap(pcm)
    }

    func stop() {
        if isExternal {
            lock.lock()
            pending.removeAll()
            pendingFrameOffset = 0
            pendingFrameCount = 0
            resetDriftLocked()
            lock.unlock()
            running = false
            return
        }
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let sink = sinkNode {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
            sinkNode = nil
        }
        // Tear down the monitor alongside capture.
        stopMonitor()
        lock.lock()
        pending.removeAll()
        pendingFrameOffset = 0
        pendingFrameCount = 0
        // A restarted device has a new backlog; re-learn the target.
        resetDriftLocked()
        lock.unlock()
        running = false
    }

    /// Record a `start()` failure without re-throwing, so other
    /// channels can keep running. Called by `AudioMixer` when a
    /// per-channel start throws.
    func recordStartFailure(_ message: String) {
        lock.lock()
        lastError = message
        lock.unlock()
        running = false
    }

    // MARK: - Tap → converted buffer → pending queue

    private func handleTap(_ inBuf: AVAudioPCMBuffer, when: AVAudioTime? = nil) {
        lock.lock()
        deliveredSinceStart = true
        if let when { noteTapTimeLocked(when, rate: inBuf.format.sampleRate) }
        lock.unlock()
        // Tap-firing diagnostic. First call + every 500th call get
        // logged (~1 log per 10 s at 48 kHz / 1024 frames per tap).
        // A plateauing counter pinpoints when the tap stopped firing.
        tapCallCount += 1
        if tapCallCount == 1 || tapCallCount % 500 == 0 {
            print("AudioInputChannel[\(label)]: tap call #\(tapCallCount), inFrames=\(inBuf.frameLength), inRate=\(inBuf.format.sampleRate)Hz")
        }

        guard let converter else { return }

        let inRate = inBuf.format.sampleRate
        let ratio = outputFormat.sampleRate / inRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        var supplied = false
        // Use `.noDataNow` (NOT `.endOfStream`) when the input has
        // been consumed. `.endOfStream` permanently retires the
        // converter — after the first tap call's conversion, the
        // converter refuses to produce any more output even though
        // the tap keeps delivering fresh buffers. `.noDataNow` tells
        // the converter to drain the input we just gave it but stay
        // alive for the next call.
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if !supplied {
                supplied = true
                outStatus.pointee = .haveData
                return inBuf
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        if status == .error {
            lastError = error?.localizedDescription ?? "converter error"
            return
        }
        guard outBuf.frameLength > 0 else { return }

        // Apply gain in place. Output is interleaved Float32 stereo:
        // a single planar buffer of frameLength * 2 floats.
        var rms: Float = 0
        var peak: Float = 0
        if let raw = outBuf.floatChannelData?.pointee {
            let totalSamples = Int(outBuf.frameLength) * Int(kMixerChannels)
            var g = gain
            let n = vDSP_Length(totalSamples)
            // Vectorised (Accelerate): gain, then RMS and peak for the
            // meters, over post-gain samples.
            if g != 1.0 { vDSP_vsmul(raw, 1, &g, raw, 1, n) }
            if totalSamples > 0 {
                vDSP_rmsqv(raw, 1, &rms, n)
                vDSP_maxmgv(raw, 1, &peak, n)
            }
        }

        // Convert linear amplitude → dBFS, clamp.
        let rmsDb = Self.linearToDbfs(rms)
        let peakDb = Self.linearToDbfs(peak)

        // Live monitor playback. `outBuf` is interleaved (required
        // for `CMSampleBuffer` construction) but `AVAudioEngine`'s
        // mixer nodes need non-interleaved (planar) PCM. De-interleave
        // into a `monitorFormat` buffer and schedule that on the
        // player node. `AVAudioPlayerNode.scheduleBuffer` copies the
        // buffer contents internally so the source can be released
        // immediately after.
        if monitorRunning, !monitorUsesRing,
           let monitorBuf = AVAudioPCMBuffer(pcmFormat: monitorFormat, frameCapacity: outBuf.frameLength),
           let interleavedSrc = outBuf.floatChannelData?.pointee,
           let monitorChannels = monitorBuf.floatChannelData {
            monitorBuf.frameLength = outBuf.frameLength
            let frameCount = Int(outBuf.frameLength)
            let channelCount = Int(monitorFormat.channelCount)
            for ch in 0..<channelCount {
                let dest = monitorChannels[ch]
                for f in 0..<frameCount {
                    dest[f] = interleavedSrc[f * channelCount + ch]
                }
            }
            // Bounded latency: the capture device and the output run
            // on different clocks, so over a long session queued audio
            // can pile up and the monitor drifts further behind the
            // picture. Normally under one chunk is waiting; past 1.5
            // chunks, skip this one to snap back (one brief blip
            // instead of a delay that keeps growing).
            let frames = Int(monitorBuf.frameLength)
            monitorLock.lock()
            let queued = monitorQueuedFrames
            let skip = queued + frames > Int(Double(frames) * 2.5)
            if !skip { monitorQueuedFrames += frames } else { monitorSkips &+= 1 }
            monitorLock.unlock()
            if !skip {
                monitorPlayerNode.scheduleBuffer(monitorBuf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.monitorLock.lock()
                    self.monitorQueuedFrames = max(0, self.monitorQueuedFrames - frames)
                    self.monitorLock.unlock()
                }
            }
        }

        lock.lock()
        pending.append(outBuf)
        pendingFrameCount &+= outBuf.frameLength
        convertedFramesPushed &+= Int(outBuf.frameLength)
        if pendingFrameCount > maxPendingFrames {
            trimmedFrames &+= Int(dropOldestLocked(pendingFrameCount - trimTargetFrames))
        }
        // Smooth RMS for a stable VU display (one-pole low-pass).
        let alpha: Float = 0.4
        smoothedRmsDbfs = (alpha * rmsDb) + ((1 - alpha) * smoothedRmsDbfs)
        lastPeakDbfs = peakDb
        lock.unlock()
    }

    /// Linear 0..1 → dBFS. Floor at -120 dB to avoid -infinity in
    /// the UI.
    private static func linearToDbfs(_ x: Float) -> Float {
        guard x > 0 else { return -120.0 }
        let db = 20.0 * log10f(x)
        return db < -120.0 ? -120.0 : db
    }

    // MARK: - Mixer pull API

    /// True once the tap has delivered at least one buffer since the
    /// last `start()`. The mixer's start watchdog uses this to catch an
    /// engine that reported "started" but never delivers audio.
    var hasDeliveredAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return deliveredSinceStart
    }

    /// Throw away everything captured so far. Called by the mixer once
    /// all channels are running and the clock is anchored, so every
    /// source starts in sync. Without this, a channel that started
    /// earlier (the first engine up, while the next one spins up)
    /// carries that head start as permanent latency.
    func discardPending() {
        lock.lock()
        pending.removeAll()
        pendingFrameOffset = 0
        pendingFrameCount = 0
        primed = false
        // Trims before alignment are the startup window, not drift.
        trimmedFrames = 0
        resetDriftLocked()
        driftDrops = 0
        driftRepeats = 0
        lock.unlock()
    }

    /// Drop up to `frames` of the oldest pending audio. Lock held.
    private func dropOldestLocked(_ frames: AVAudioFrameCount) -> AVAudioFrameCount {
        var dropped: AVAudioFrameCount = 0
        while dropped < frames, let buf = pending.first {
            let available = buf.frameLength - pendingFrameOffset
            let take = min(available, frames - dropped)
            dropped &+= take
            pendingFrameOffset &+= take
            pendingFrameCount &-= take
            if pendingFrameOffset >= buf.frameLength {
                pending.removeFirst()
                pendingFrameOffset = 0
            }
        }
        return dropped
    }

    /// Pull up to `frames` frames into `dest`, summing into existing
    /// content. `dest` is interleaved Float32 stereo
    /// (kMixerChannels samples per frame). Returns the number of
    /// frames actually summed in (the rest is unchanged — caller
    /// should zero-fill at allocation time, this only adds).
    @discardableResult
    func pull(intoSummed dest: UnsafeMutablePointer<Float>, frames: AVAudioFrameCount) -> AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }

        // Jitter buffer: hold output until enough audio is queued.
        // Waiting to prime isn't an underrun, so it isn't counted.
        if !primed {
            guard pendingFrameCount >= primeFrames else { return 0 }
            primed = true
        }

        // Clock-drift correction for this pull: +1 drop a frame,
        // -1 repeat one, 0 neither.
        let correction = driftCorrectionLocked(frames: frames)
        if correction > 0, pendingFrameCount > frames {
            _ = dropOldestLocked(1)
            driftDrops &+= 1
        }
        let repeatLast = correction < 0 && frames > 1
        let target = repeatLast ? frames - 1 : frames

        var produced: AVAudioFrameCount = 0
        var destIdx = 0  // sample index (interleaved, so frame*kMixerChannels)
        var lastFrame: (Float, Float)?

        while produced < target, let buf = pending.first {
            let availableInBuf = buf.frameLength - pendingFrameOffset
            let want = target - produced
            let take = min(availableInBuf, want)
            if take == 0 { break }

            if let raw = buf.floatChannelData?.pointee {
                let srcStart = Int(pendingFrameOffset) * Int(kMixerChannels)
                let count = Int(take) * Int(kMixerChannels)
                // Sum src → dest
                for i in 0..<count {
                    dest[destIdx + i] += raw[srcStart + i]
                }
                lastFrame = (raw[srcStart + count - 2], raw[srcStart + count - 1])
            }

            destIdx += Int(take) * Int(kMixerChannels)
            produced &+= take
            pendingFrameOffset &+= take
            pendingFrameCount &-= take

            if pendingFrameOffset >= buf.frameLength {
                pending.removeFirst()
                pendingFrameOffset = 0
            }
        }

        // Repeat the last frame to fill the slot the correction left.
        if repeatLast, produced == target, let (l, r) = lastFrame {
            dest[destIdx] += l
            dest[destIdx + 1] += r
            produced &+= 1
            driftRepeats &+= 1
        }

        framesPulledByMixer &+= Int(produced)
        if produced < frames {
            zeroFillEvents &+= 1
            primed = false
        }
        return produced
    }

    /// This pull's correction: +1 drop a frame, -1 repeat one, 0
    /// neither, paced at the measured device drift. Lock held.
    private func driftCorrectionLocked(frames: AVAudioFrameCount) -> Int {
        #if DEBUG
        backlogSum += Double(pendingFrameCount)
        backlogSamples += 1
        if Self.driftCorrectionDisabledForTesting { return 0 }
        #endif
        guard let ppm = driftPPMValue else { return 0 }
        return driftPacer.next(frames: Int(frames), ppm: ppm)
    }

    // MARK: - Stats

    /// Current meter levels (dBFS), or nil when not running. A cheap
    /// read for 30 Hz meters; `snapshot()` copies every counter.
    func levels() -> (rms: Float, peak: Float)? {
        guard running else { return nil }
        lock.lock(); defer { lock.unlock() }
        return (smoothedRmsDbfs, lastPeakDbfs)
    }

    func snapshot() -> AudioInputChannelStats {
        lock.lock()
        let pushed = convertedFramesPushed
        let pulled = framesPulledByMixer
        let zf = zeroFillEvents
        let trimmed = trimmedFrames
        let drops = driftDrops
        let repeats = driftRepeats
        let ppm = driftPPMValue
        let err = lastError
        let rmsDb = smoothedRmsDbfs
        let peakDb = lastPeakDbfs
        lock.unlock()
        return AudioInputChannelStats(
            label: label,
            deviceLabel: deviceLabel,
            enabled: enabled,
            running: running,
            gain: gain,
            nativeSampleRate: nativeFormat?.sampleRate ?? 0,
            nativeChannels: Int(nativeFormat?.channelCount ?? 0),
            convertedFramesPushed: pushed,
            framesPulledByMixer: pulled,
            zeroFillEvents: zf,
            trimmedFrames: trimmed,
            driftDrops: drops,
            driftRepeats: repeats,
            driftPPM: ppm,
            recoveries: recoveryCount,
            lastRecoveryReason: lastRecoveryReason,
            lastError: err,
            rmsDbfs: rmsDb,
            peakDbfs: peakDb
        )
    }

    // MARK: - Core Audio device routing

    /// Translate an AVCaptureDevice uniqueID (or AudioSource.id from
    /// DeviceCatalog, which is the same string) into a Core Audio
    /// AudioDeviceID. AVCaptureDevice's audio uniqueID matches
    /// kAudioDevicePropertyDeviceUID on macOS.
    static func audioDeviceID(forUID targetUID: String) throws -> AudioDeviceID {
        var size = UInt32(0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var st = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard st == noErr else {
            throw CaptureError.configurationFailed("CoreAudio devices size: \(st)")
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
        guard st == noErr else {
            throw CaptureError.configurationFailed("CoreAudio devices data: \(st)")
        }

        for dev in devices {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfStr: Unmanaged<CFString>? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            let st2 = AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &cfStr)
            if st2 == noErr, let cfStr = cfStr {
                let uid = cfStr.takeRetainedValue() as String
                if uid == targetUID {
                    return dev
                }
            }
        }
        throw CaptureError.configurationFailed("No Core Audio device matches UID: \(targetUID)")
    }

    /// Set an AVAudioEngine's input audio unit to a specific Core
    /// Audio device. The engine's underlying audio unit is an AUHAL
    /// (kAudioUnitSubType_HALOutput). On macOS, setting
    /// kAudioOutputUnitProperty_CurrentDevice routes input from that
    /// physical device.
    static func setEngineInputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        var devID = deviceID
        let st: OSStatus = try engine.inputNode.withAudioUnit { unit in
            guard let unit else {
                throw CaptureError.configurationFailed("Engine has no input audioUnit")
            }
            return AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        guard st == noErr else {
            throw CaptureError.configurationFailed("AudioUnitSetProperty(CurrentDevice): \(st)")
        }
    }

    /// Read back the audio unit's current device. Used after
    /// `setEngineInputDevice()` to verify that the bind actually
    /// took (the AUHAL can silently fall back to the system default
    /// input).
    static func currentEngineInputDeviceID(engine: AVAudioEngine) throws -> AudioDeviceID {
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st: OSStatus = try engine.inputNode.withAudioUnit { unit in
            guard let unit else {
                throw CaptureError.configurationFailed("Engine has no input audioUnit")
            }
            return AudioUnitGetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                &size
            )
        }
        guard st == noErr else {
            throw CaptureError.configurationFailed("AudioUnitGetProperty(CurrentDevice): \(st)")
        }
        return devID
    }
}

// MARK: - AudioMixer

/// Pulls fixed chunks from each enabled channel, sums, emits a
/// CMSampleBuffer at canonical mixer format. Driven by a serial
/// DispatchSourceTimer, decoupled from any single channel's tap
/// cadence.
final class AudioMixer: @unchecked Sendable {

    private let outputFormat: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private let channels: [AudioInputChannel]

    /// Called on the mixer's emission queue with each mixed buffer.
    var onMixedSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called on the emission queue with each running channel's own
    /// post-gain buffer (label, buffer), carrying the same PTS as the
    /// mix. The recorder writes these as per-source tracks.
    var onChannelSampleBuffer: ((String, CMSampleBuffer) -> Void)?

    private let emissionQueue = DispatchQueue(label: "recaptr.mixer.emission", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private(set) var running = false

    private var sampleClock: Int64 = 0  // monotonic frame counter for PTS
    private(set) var mixedFramesEmitted: Int = 0
    private(set) var ticks: Int = 0

    /// Host clock time captured at `start()`. Mixer PTS is computed as
    /// `startClockTime + sampleClock / sampleRate` so it shares the
    /// time domain with `AVCaptureSession`'s video PTSes — otherwise
    /// audio samples land before the writer's session anchor and get
    /// dropped.
    private var startClockTime: CMTime = .invalid

    private var formatDescription: CMAudioFormatDescription?

    /// One linked limiter: gain comes from the sum of all sources and
    /// is applied to the sum and every source alike. Multi-source files
    /// carry one track per source and players add them together, so
    /// the sum must stay under full scale with the balance unchanged.
    /// Emission queue only.
    private var limiter = PeakLimiter()

    init(channels: [AudioInputChannel],
         outputFormat: AVAudioFormat = makeMixerFormat(),
         chunkFrames: AVAudioFrameCount = kMixerChunkFrames) {
        self.channels = channels
        self.outputFormat = outputFormat
        self.chunkFrames = chunkFrames
        for ch in channels {
            ch.onConfigurationChange = { [weak self] ch in
                self?.recover(ch, reason: "audio hardware changed")
            }
        }
    }

    /// Called with a human-readable note whenever a channel is
    /// recovered or given up on, so the UI can say so.
    var onChannelEvent: ((String) -> Void)?

    func channel(at index: Int) -> AudioInputChannel? {
        channels.indices.contains(index) ? channels[index] : nil
    }

    var allChannels: [AudioInputChannel] { channels }

    /// Labels of channels currently feeding the mix.
    var runningChannelLabels: [String] {
        channels.filter { $0.enabled && $0.running }.map(\.label)
    }

    var hasAnyEnabledChannel: Bool {
        channels.contains { $0.isArmed }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }

        // 1. Build CM format description (lazy on first emission would
        // also work, but doing it up front surfaces format errors at
        // start time instead of mid-stream).
        formatDescription = try Self.makeFormatDescription(from: outputFormat)

        // 2. Start every enabled channel that has a device.
        //
        // Graceful per-channel start: macOS HAL refuses two
        // simultaneous `AVAudioEngine` input bindings to different
        // physical devices (the second `engine.start()` throws
        // `kAudioServerStopErr` = 1937010544 = "stop"). Propagating
        // that throw would kill the already-running channel's path
        // because the mixer would never reach its `timer.resume()`.
        // Instead, record the per-channel failure and continue —
        // the mixer succeeds as long as at least one channel started.
        var anyStarted = false
        for ch in channels where ch.isArmed {
            do {
                try ch.start()
                anyStarted = true
                // Fire up the monitor engine if the channel was
                // configured with monitoring on. No-op when
                // `monitorEnabled` is false.
                ch.startMonitorIfNeeded()
            } catch {
                ch.recordStartFailure(error.localizedDescription)
                print("AudioMixer: channel '\(ch.label)' failed to start: \(error.localizedDescription) — continuing with remaining channels")
            }
        }
        guard anyStarted else {
            throw CaptureError.configurationFailed("No audio channels could start")
        }

        limiter = PeakLimiter()

        // 3. Align sources. Channels start one after another, so the
        //    first one up has already buffered audio from before the
        //    clock anchor below. Drop it so every source (and the
        //    video) starts from the same moment.
        for ch in channels { ch.discardPending() }

        // 4. Reset clocks. Capture the host clock so audio PTS shares
        //    the time domain with `AVCaptureSession`'s video frames.
        sampleClock = 0
        mixedFramesEmitted = 0
        ticks = 0
        catchUpChunks = 0
        let hostClock = CMClockGetHostTimeClock()
        startClockTime = CMClockGetTime(hostClock)
        print("AudioMixer: start clock anchored at host time \(CMTimeGetSeconds(startClockTime))s")

        // 5. Schedule the timer. 1024 / 48000 = ~21.3ms.
        let interval = Double(chunkFrames) / outputFormat.sampleRate
        let t = DispatchSource.makeTimerSource(queue: emissionQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        running = true
        t.resume()

        scheduleStartWatchdog(attempt: 1)
        startRuntimeWatchdog()

        // UI tests: `-RecaptrUITestStallMixer <seconds>` blocks the
        // emission queue 6 s after start, like a heavily loaded system
        // delaying the mixer's timer.
        if UserDefaults.standard.bool(forKey: "RecaptrUITesting") {
            let stall = UserDefaults.standard.double(forKey: "RecaptrUITestStallMixer")
            if stall > 0 {
                emissionQueue.asyncAfter(deadline: .now() + 6) {
                    print("AudioMixer: TEST stalling emission for \(stall) s")
                    Thread.sleep(forTimeInterval: stall)
                }
            }
        }

        // UI tests: `-RecaptrUITestSimulateAudioReset notify|silent`
        // stops the device engines 6 s after start, as macOS does on
        // an audio hardware change, with or without the notification.
        if UserDefaults.standard.bool(forKey: "RecaptrUITesting"),
           let mode = UserDefaults.standard.string(forKey: "RecaptrUITestSimulateAudioReset") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.running else { return }
                print("AudioMixer: TEST simulating audio reset (\(mode))")
                if mode == "down", let ch = self.channels.first(where: { $0.running && !$0.isExternal }) {
                    // Source device gone for 3 s, then back.
                    ch.unavailableUntilForTesting = Date().addingTimeInterval(3)
                    ch.stop()
                    return
                }
                for ch in self.channels where ch.running {
                    ch.simulateEngineStopForTesting(notify: mode == "notify")
                }
            }
        }
    }

    // MARK: - Runtime watchdog

    /// Once running, a device channel that captures nothing for
    /// `stallTimeout` is restarted, at any point in the session (the
    /// start watchdog only covers startup). External channels are
    /// skipped: their audio comes from SCStream, which this can't
    /// restart. After `maxConsecutiveRecoveries` restarts without
    /// progress, the channel is flagged instead of retried forever.
    private var runtimeWatchdog: DispatchSourceTimer?
    private var lastPushed: [ObjectIdentifier: (frames: Int, since: Date)] = [:]
    private var failedRecoveries: [ObjectIdentifier: Int] = [:]
    private var nextRetry: [ObjectIdentifier: Date] = [:]
    private let stallTimeout: TimeInterval = 1.5
    private let maxConsecutiveRecoveries = 5

    private func startRuntimeWatchdog() {
        lastPushed = [:]
        failedRecoveries = [:]
        nextRetry = [:]
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Start after the startup watchdog's window (4 x 0.6 s) so the
        // two never restart the same slow-starting channel.
        t.schedule(deadline: .now() + 3, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkForStalls() }
        runtimeWatchdog = t
        t.resume()
    }

    private func checkForStalls() {
        guard running else { return }
        let now = Date()
        for ch in channels where ch.isArmed && !ch.isExternal {
            let id = ObjectIdentifier(ch)
            // A channel that's down (a restart failed, device briefly
            // gone during an HDMI mode change) is retried with back-off
            // instead of being left dead for the rest of the session.
            guard ch.running else {
                if now >= (nextRetry[id] ?? .distantPast) {
                    let attempt = (failedRecoveries[id] ?? 0) + 1
                    nextRetry[id] = now.addingTimeInterval(min(5, 1.5 * Double(attempt)))
                    recover(ch, reason: "device unavailable")
                }
                continue
            }
            let pushed = ch.pushedFrameCount
            guard let last = lastPushed[id], last.frames == pushed else {
                if lastPushed[id] != nil { failedRecoveries[id] = 0 }
                lastPushed[id] = (pushed, now)
                continue
            }
            if now.timeIntervalSince(last.since) >= stallTimeout {
                lastPushed[id] = (pushed, now)
                recover(ch, reason: "no audio for \(stallTimeout) s")
            }
        }
    }

    /// Restart one channel in place. Main queue.
    private func recover(_ ch: AudioInputChannel, reason: String) {
        guard running, ch.isArmed, !ch.isExternal else { return }
        let id = ObjectIdentifier(ch)
        let failures = (failedRecoveries[id] ?? 0) + 1
        failedRecoveries[id] = failures
        if failures == maxConsecutiveRecoveries + 1 {
            // Say so once, then keep retrying quietly with back-off;
            // the track keeps running with silence meanwhile.
            onChannelEvent?("\(ch.label) audio keeps dropping out. Recaptr will keep retrying; check the device.")
        }
        print("AudioMixer: recovering '\(ch.label)' (\(reason), attempt \(failures))")
        ch.stop()
        do {
            try ch.start()
            ch.startMonitorIfNeeded()
            ch.noteRecovery(reason: reason)
            if failures <= maxConsecutiveRecoveries {
                onChannelEvent?("\(ch.label) audio restarted (\(reason)).")
            }
        } catch {
            ch.recordStartFailure(error.localizedDescription)
        }
    }

    // MARK: - Start watchdog

    /// With two input engines running, macOS 27 occasionally leaves
    /// one "started" but silent after a stop/start (measured
    /// 2026-09-26: roughly 1 in 4 source switches, either channel).
    /// Taps deliver every ~100 ms, so a channel with nothing after
    /// `watchdogDelay` is restarted, up to `maxWatchdogAttempts`
    /// times. If it's still silent the channel records an error, which
    /// shows in the status line, instead of silently recording zeros.
    private let watchdogDelay: TimeInterval = 0.6
    private let maxWatchdogAttempts = 3

    private func scheduleStartWatchdog(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogDelay) { [weak self] in
            self?.checkStartWatchdog(attempt: attempt)
        }
    }

    private func checkStartWatchdog(attempt: Int) {
        guard running else { return }
        let silent = channels.filter { $0.enabled && $0.running && !$0.hasDeliveredAudio }
        guard !silent.isEmpty else { return }

        for ch in silent {
            guard attempt <= maxWatchdogAttempts else {
                ch.stop()
                ch.recordStartFailure("no audio from device after \(maxWatchdogAttempts) restarts")
                print("AudioMixer: watchdog gave up on '\(ch.label)'")
                continue
            }
            print("AudioMixer: watchdog restarting silent channel '\(ch.label)' (attempt \(attempt))")
            ch.stop()
            do {
                try ch.start()
                ch.startMonitorIfNeeded()
                ch.discardPending()
            } catch {
                ch.recordStartFailure(error.localizedDescription)
            }
        }
        if attempt <= maxWatchdogAttempts {
            scheduleStartWatchdog(attempt: attempt + 1)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        runtimeWatchdog?.cancel()
        runtimeWatchdog = nil
        for ch in channels { ch.stop() }
        running = false
        startClockTime = .invalid  // reset for the next start()
    }

    // MARK: - Tick → mix → emit

    private func tick() {
        guard running else { return }
        ticks &+= 1

        // Emit every chunk that's due by the host clock, not one per
        // tick. A dispatch timer that falls behind (busy system, 4K
        // encoding, background throttling) drops the missed firings;
        // emitting one chunk per tick then made the audio timeline run
        // slow: a 17.5-minute 4K take ended 2.0 s short of the video
        // and a 2 s stall lost exactly 2 s (2026-09-26). Catching up
        // keeps audio locked to real time.
        guard startClockTime.isValid else { emitChunk(); return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), startClockTime))
        let due = Int64(elapsed * outputFormat.sampleRate)
        var emitted = 0
        while sampleClock + Int64(chunkFrames) <= due, emitted < maxCatchUpChunks {
            emitChunk()
            emitted += 1
        }
        if emitted > 1 { catchUpChunks &+= emitted - 1 }
    }

    /// Upper bound on chunks emitted in one tick (~10 s of audio), so
    /// a very long stall can't produce one enormous burst.
    private let maxCatchUpChunks = 470
    /// Chunks emitted late to catch up with the clock. Diagnostic.
    private(set) var catchUpChunks = 0

    /// Pull one chunk from every armed channel, mix, limit, and emit
    /// the mix plus per-source buffers at the next sample-clock PTS.
    private func emitChunk() {
        let frames = chunkFrames
        let sampleCount = Int(frames) * Int(kMixerChannels)

        // Working buffer (the sum), zeroed.
        var working = [Float](repeating: 0, count: sampleCount)
        var anyChannelActive = false
        // Each channel is pulled into its own buffer so it can be
        // emitted as a per-source track, then summed into the mix.
        // Raw buffers so the linked limiter can adjust them together.
        var isolated: [(label: String, samples: UnsafeMutablePointer<Float>)] = []
        defer { for item in isolated { item.samples.deallocate() } }

        // Every armed channel emits a buffer every tick, silence while
        // it's down (restarting, device gone). Skipping a down channel
        // made its per-source track shorter than the others, so
        // everything after the gap played early: a 5-minute 4K take
        // lost 2.4 s of game audio this way (2026-09-26).
        for ch in channels where ch.isArmed {
            let own = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            own.initialize(repeating: 0, count: sampleCount)
            if ch.running {
                anyChannelActive = true
                _ = ch.pull(intoSummed: own, frames: frames)
            }
            for i in 0..<sampleCount { working[i] += own[i] }
            isolated.append((ch.label, own))
        }
        working.withUnsafeMutableBufferPointer {
            limiter.processLinked(sum: $0.baseAddress!, sources: isolated.map(\.samples),
                                  sampleCount: sampleCount, channels: Int(kMixerChannels))
        }

        // If no channel is enabled+running, emit silence (still
        // monotonic — keeps the audio track aligned with video).
        // If anyChannelActive is false but we're "running", that's
        // most likely a brief startup window; emit silence too.
        _ = anyChannelActive

        // Wrap in CMSampleBuffer.
        // All buffers for this tick share one PTS, so build them all
        // before advancing the sample clock.
        guard let fmt = formatDescription else { return }
        guard let sb = makeSampleBuffer(samples: working, frameCount: Int(frames), format: fmt) else { return }
        var channelBuffers: [(String, CMSampleBuffer)] = []
        if onChannelSampleBuffer != nil {
            for (label, samples) in isolated {
                let array = Array(UnsafeBufferPointer(start: samples, count: sampleCount))
                if let csb = makeSampleBuffer(samples: array, frameCount: Int(frames), format: fmt) {
                    channelBuffers.append((label, csb))
                }
            }
        }
        mixedFramesEmitted &+= Int(frames)
        sampleClock &+= Int64(frames)

        onMixedSampleBuffer?(sb)
        for (label, csb) in channelBuffers {
            onChannelSampleBuffer?(label, csb)
        }
    }

    // MARK: - CMSampleBuffer construction

    private func makeSampleBuffer(samples: [Float], frameCount: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytesPerFrame = Int(kMixerChannels) * MemoryLayout<Float>.size
        let totalBytes = frameCount * bytesPerFrame

        // Allocate a malloc'd block — CMBlockBufferCreateWithMemoryBlock will own/free it.
        guard let memory = malloc(totalBytes) else { return nil }
        samples.withUnsafeBufferPointer { srcPtr in
            if let src = srcPtr.baseAddress {
                memcpy(memory, src, totalBytes)
            }
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memory,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorMalloc,  // ← will free `memory` when block buffer dies
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else {
            free(memory)
            return nil
        }

        // PTS in the host time domain. `startClockTime` was captured
        // at `start()`; add the `sampleClock`-relative offset so each
        // emit advances monotonically at exactly 48 kHz.
        let elapsed = CMTime(value: sampleClock, timescale: CMTimeScale(kMixerSampleRate))
        let pts = startClockTime.isValid
            ? CMTimeAdd(startClockTime, elapsed)
            : CMTime(value: sampleClock, timescale: CMTimeScale(kMixerSampleRate))
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,  // PCM → no packet descriptions needed
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }
        return sampleBuffer
    }

    private static func makeFormatDescription(from format: AVAudioFormat) throws -> CMAudioFormatDescription {
        var asbd = format.streamDescription.pointee
        var fmt: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard st == noErr, let fmt else {
            throw CaptureError.configurationFailed("CMAudioFormatDescriptionCreate: \(st)")
        }
        return fmt
    }

    // MARK: - Stats

    func snapshot() -> AudioMixerStats {
        AudioMixerStats(
            running: running,
            mixedFramesEmitted: mixedFramesEmitted,
            ticks: ticks,
            catchUpChunks: catchUpChunks,
            channels: channels.map { $0.snapshot() }
        )
    }
}
