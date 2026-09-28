//
//  AudioMixer.swift
//  Recaptr
//
//  Per-source audio capture and a host-clocked mixer that feeds the
//  recorder, plus the live monitor.

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
    /// Frames dropped to keep the backlog bounded. Zero in a normal session.
    var trimmedFrames: Int = 0
    /// Drift corrections: frames dropped (device fast) and repeated (device slow).
    var driftDrops: Int = 0
    var driftRepeats: Int = 0
    /// Device clock error in ppm (positive means fast). Nil until measured.
    var driftPPM: Double?
    /// Automatic restarts after a stall or audio hardware change.
    var recoveries: Int = 0
    var lastRecoveryReason: String?
    var lastError: String?
    /// Smoothed RMS of the last converted buffer, in dBFS.
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

/// Mixer format: 48 kHz stereo Float32, interleaved so one CMBlockBuffer
/// wraps each chunk.
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

/// Paces drift corrections: each pull returns +1 (drop a frame), -1
/// (repeat one), or 0, so `ppm` millionths of frames are corrected over
/// time, never more than one per pull.
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

/// One input source with its own AVAudioEngine bound to a physical device.
nonisolated final class AudioInputChannel: @unchecked Sendable {

    let label: String
    private let outputFormat: AVAudioFormat
    /// Non-interleaved format for the monitor graph. Mixer nodes reject
    /// interleaved formats, and `outputFormat` is interleaved.
    private let monitorFormat: AVAudioFormat

    // Configuration: set before start(), locked while running.
    var deviceUniqueID: String?
    var deviceLabel: String = "—"
    var gain: Float = 1.0 {
        didSet { monitorRing.gain = gain }
    }
    var enabled: Bool = true

    /// Low-latency monitor feed, written by `sinkNode` and read by the
    /// monitor engine. With no sink (input not 48 kHz Float32, or more than
    /// two channels) the monitor schedules tap buffers on a player node.
    let monitorRing = MonitorRing()
    private var sinkNode: AVAudioSinkNode?
    /// True when the current monitor engine plays from `monitorRing`.
    private var monitorUsesRing = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var tapInstalled = false
    private(set) var running = false

    // Pending converted buffers and counters, guarded by `lock`.
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrameOffset: AVAudioFrameCount = 0  // index into pending.first
    private var pendingFrameCount: AVAudioFrameCount = 0
    /// Backlog cap. Taps deliver ~100 ms per callback. Past 250 ms the oldest
    /// audio is dropped back to `trimTargetFrames`, so a fast device clock
    /// can't push this source out of sync.
    private let maxPendingFrames: AVAudioFrameCount = 12_000
    private let trimTargetFrames: AVAudioFrameCount = 6_000
    private var trimmedFrames: Int = 0

    /// Clock-drift compensation for device channels. Each device runs on its
    /// own clock while the mixer pulls on the host clock, so a slightly fast
    /// device builds backlog and its audio falls behind (a few tens of ppm
    /// is ~100 ms an hour). The rate is measured from tap timestamps, device
    /// sample time against host time, and one frame is dropped or repeated
    /// at that rate. Don't estimate drift from the backlog: a late mixer
    /// timer looks like extra backlog and the correction causes underruns.
    private var driftFirstStamp: (sample: Double, host: Double)?
    private var driftPPMValue: Double?
    private var driftPacer = DriftPacer()
    private var driftDrops = 0
    private var driftRepeats = 0
    #if DEBUG
    /// UI tests: average backlog per pull since the last read.
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

    /// External channels: frames delivered since the first stamp.
    private var externalFramesSinceFirst: Double = 0

    /// Updates the rate estimate from an external buffer's host-time stamp.
    /// Lock held.
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

    /// Jitter buffer for external channels. SCStream delivers small, irregular
    /// chunks, so the channel waits for `primeFrames` (~43 ms) before feeding
    /// the mix and re-primes after an underrun. Without it each underrun
    /// inserts a sliver of silence (crackle).
    private var primeFrames: AVAudioFrameCount { isExternal ? 2_048 : 0 }
    private var primed = false
    private(set) var convertedFramesPushed: Int = 0
    private(set) var framesPulledByMixer: Int = 0
    private(set) var zeroFillEvents: Int = 0
    private(set) var lastError: String?

    // VU meter state, read by `snapshot()` under lock.
    private var smoothedRmsDbfs: Float = -120.0
    private var lastPeakDbfs: Float = -120.0

    /// Tap call counter, logged on the first call and every 500th. A counter
    /// that stops growing means the tap stalled.
    private var tapCallCount: Int = 0
    /// Set by the first tap callback after `start()`. Guarded by `lock`.
    private var deliveredSinceStart = false

    // Live monitor: a separate output-only engine, which avoids the HAL
    // conflict with the input engine. These are `var` because the engine is
    // rebuilt on each toggle-on: `outputNode` binds to the default output at
    // start and doesn't follow later changes.
    private var monitorEngine = AVAudioEngine()
    private var monitorPlayerNode = AVAudioPlayerNode()
    private var monitorRunning = false
    /// Checked in handleTap. Turning it on after start() also needs
    /// startMonitorIfNeeded().
    var monitorEnabled: Bool = false
    /// 0…1.5, the same ceiling as the input gain.
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
        // Non-interleaved Float32, which mixer nodes accept.
        self.monitorFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputFormat.sampleRate,
            channels: outputFormat.channelCount
        ) ?? outputFormat

        // Initial graph. It's replaced on the first toggle-on so it binds to
        // the then-current default output.
        buildMonitorEngine()

        // macOS stops a running engine when the audio hardware changes (for
        // example the default output switching). The mixer restarts the
        // channel; otherwise capture records silence.
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

    /// UI tests only: while set, `start()` fails as if the device had vanished.
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

    /// Builds a fresh monitor engine and graph. Called on every toggle-on
    /// because `outputNode` binds to the default output at engine start and
    /// doesn't follow later changes.
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

        // The output device changed and macOS stopped this engine. Rebuild it
        // on the new default output.
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

    /// Monitor audio scheduled but not yet played, and chunks skipped to
    /// bound latency. Guarded by monitorLock (completion handlers run on an
    /// audio thread).
    private let monitorLock = NSLock()
    private var monitorQueuedFrames = 0
    private(set) var monitorSkips = 0

    /// Starts the monitor if `monitorEnabled` is set. Idempotent. Rebuilds
    /// the engine each time so it plays on the current default output.
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

    /// Toggles the monitor without restarting capture.
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

        let coreAudioID = try Self.audioDeviceID(forUID: deviceUID)
        print("AudioInputChannel[\(label)]: resolved UID '\(deviceUID)' → CoreAudio device \(coreAudioID)")

        try Self.setEngineInputDevice(engine: engine, deviceID: coreAudioID)
        // Read it back: the AUHAL can silently fall back to the default input.
        if let actualID = try? Self.currentEngineInputDeviceID(engine: engine), actualID != coreAudioID {
            print("AudioInputChannel[\(label)]: WARNING device mismatch after set — wanted \(coreAudioID), got \(actualID)")
        }

        let format = engine.inputNode.inputFormat(forBus: 0)
        print("AudioInputChannel[\(label)]: native format \(format.sampleRate)Hz × \(format.channelCount)ch (\(format.commonFormat.rawValue))")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.configurationFailed("\(label): native format has zero rate/channels (mic permission denied?)")
        }
        nativeFormat = format

        guard let conv = AVAudioConverter(from: format, to: outputFormat) else {
            throw CaptureError.configurationFailed("\(label): could not build converter \(format) → \(outputFormat)")
        }
        converter = conv

        // Uses the deprecated `installTap` on purpose. `installAudioTap` delivers
        // nothing after a channel stop/start, leaving a silent track, and its
        // 100 ms minimum buffer adds monitor latency.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in
            self?.handleTap(buf, when: when)
        }
        tapInstalled = true

        // Low-latency monitor feed: a sink node copies each I/O cycle (~10 ms)
        // into the ring. The tap still feeds the recording.
        attachMonitorSink(format: format)

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
        // UI tests: `-RecaptrUITestMonitorTapPath YES` forces the tap path.
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

        // SCStream stamps buffers in host time, so drift is measured the same
        // way as for a device.
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
        stopMonitor()
        lock.lock()
        pending.removeAll()
        pendingFrameOffset = 0
        pendingFrameCount = 0
        // A restarted device starts a new drift measurement.
        resetDriftLocked()
        lock.unlock()
        running = false
    }

    /// Records a start failure without throwing, so other channels keep running.
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
        // Answer `.noDataNow`, not `.endOfStream`, once the input is consumed.
        // `.endOfStream` retires the converter and later calls produce nothing.
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

        // Output is interleaved stereo in a single buffer.
        var rms: Float = 0
        var peak: Float = 0
        if let raw = outBuf.floatChannelData?.pointee {
            let totalSamples = Int(outBuf.frameLength) * Int(kMixerChannels)
            var g = gain
            let n = vDSP_Length(totalSamples)
            // Gain, then RMS and peak of the post-gain samples.
            if g != 1.0 { vDSP_vsmul(raw, 1, &g, raw, 1, n) }
            if totalSamples > 0 {
                vDSP_rmsqv(raw, 1, &rms, n)
                vDSP_maxmgv(raw, 1, &peak, n)
            }
        }

        let rmsDb = Self.linearToDbfs(rms)
        let peakDb = Self.linearToDbfs(peak)

        // Tap-path monitor: de-interleave into `monitorFormat` (mixer nodes need
        // planar) and schedule it. scheduleBuffer copies the samples.
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
            // Bound monitor latency. Input and output run on different clocks, so
            // queued audio can pile up. Past 1.5 chunks queued, skip this one: a
            // brief blip instead of a growing delay.
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
        // One-pole low-pass for a stable VU display.
        let alpha: Float = 0.4
        smoothedRmsDbfs = (alpha * rmsDb) + ((1 - alpha) * smoothedRmsDbfs)
        lastPeakDbfs = peakDb
        lock.unlock()
    }

    /// Linear to dBFS, floored at -120 dB for the UI.
    private static func linearToDbfs(_ x: Float) -> Float {
        guard x > 0 else { return -120.0 }
        let db = 20.0 * log10f(x)
        return db < -120.0 ? -120.0 : db
    }

    // MARK: - Mixer pull API

    /// True once audio has arrived since the last `start()`. The start
    /// watchdog uses it to catch an engine that started but stays silent.
    var hasDeliveredAudio: Bool {
        lock.lock(); defer { lock.unlock() }
        return deliveredSinceStart
    }

    /// Drops everything captured so far. Called once all channels run and
    /// the clock is anchored, so no channel keeps its head start as latency.
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

    /// Adds up to `frames` frames of interleaved stereo into `dest`, which
    /// the caller zeroes. Returns the number of frames added.
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

    /// Maps an AVCaptureDevice uniqueID (also DeviceCatalog's AudioSource.id)
    /// to a Core Audio device. The two IDs match kAudioDevicePropertyDeviceUID.
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

    /// Binds the engine's input AUHAL to a Core Audio device through
    /// kAudioOutputUnitProperty_CurrentDevice.
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

    /// Reads back the AUHAL's current device to check that the bind took.
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

/// Pulls a fixed chunk from each channel on a timer, mixes, and emits
/// CMSampleBuffers. The timer is independent of any channel's tap cadence.
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

    /// Host time at `start()`. PTS is `startClockTime + sampleClock / rate`,
    /// the same time domain as the video. Audio stamped in another domain
    /// lands before the writer's session anchor and is dropped.
    private var startClockTime: CMTime = .invalid

    private var formatDescription: CMAudioFormatDescription?

    /// One linked limiter for the mix and every source. Files carry one
    /// track per source and players sum them, so the sum must stay under
    /// full scale with the balance unchanged. Emission queue only.
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

        // Built up front so format errors surface at start, not mid-stream.
        formatDescription = try Self.makeFormatDescription(from: outputFormat)

        // Start channels one by one and keep going on failure. The HAL can
        // refuse a second input engine on a different device
        // (kAudioServerStopErr), and throwing here would take down the
        // channels that did start.
        var anyStarted = false
        for ch in channels where ch.isArmed {
            do {
                try ch.start()
                anyStarted = true
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

        // Channels start one after another, so drop audio buffered before
        // the clock anchor. Every source and the video then start together.
        for ch in channels { ch.discardPending() }

        // Anchor PTS to the host clock, shared with the video frames.
        sampleClock = 0
        mixedFramesEmitted = 0
        ticks = 0
        catchUpChunks = 0
        let hostClock = CMClockGetHostTimeClock()
        startClockTime = CMClockGetTime(hostClock)
        print("AudioMixer: start clock anchored at host time \(CMTimeGetSeconds(startClockTime))s")

        // 1024 / 48000 ≈ 21.3 ms.
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

    /// Restarts a device channel that captures nothing for `stallTimeout`,
    /// at any point in the session. External channels are skipped (SCStream
    /// can't be restarted here). After `maxConsecutiveRecoveries` failures
    /// the UI is told once and retries continue with back-off.
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
            // A channel that's down (restart failed, device briefly gone) is
            // retried with back-off rather than left dead.
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

    /// With two input engines, macOS sometimes leaves one started but silent
    /// after a stop/start. Taps deliver every ~100 ms, so a channel with
    /// nothing after `watchdogDelay` is restarted, up to
    /// `maxWatchdogAttempts` times, then flagged with an error instead of
    /// silently recording zeros.
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

        // Emit every chunk due by the host clock, not one per tick. A late
        // timer skips missed firings, and one chunk per tick would let audio
        // fall behind the video.
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

        // The mix, zeroed.
        var working = [Float](repeating: 0, count: sampleCount)
        var anyChannelActive = false
        // Each channel is pulled into its own buffer for its per-source track,
        // then summed. Raw pointers so the linked limiter can scale them together.
        var isolated: [(label: String, samples: UnsafeMutablePointer<Float>)] = []
        defer { for item in isolated { item.samples.deallocate() } }

        // Every armed channel emits every tick, silence while it's down.
        // Skipping a down channel would shorten its track and shift everything
        // after the gap earlier.
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

        // With no active channel, silence is still emitted so the audio track
        // stays aligned with the video.
        _ = anyChannelActive

        // All buffers for this tick share one PTS, so build them before
        // advancing the sample clock.
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

        // The block buffer takes ownership of this memory and frees it.
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
            blockAllocator: kCFAllocatorMalloc,
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

        // PTS in host time, advancing one frame per 1/48000 s from `startClockTime`.
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
