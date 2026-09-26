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
    var gain: Float = 1.0
    var enabled: Bool = true

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
        engine.attach(player)
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: monitorFormat)
        } catch {
            print("AudioInputChannel[\(label)]: monitor connect failed: \(error.localizedDescription)")
        }
        engine.mainMixerNode.outputVolume = monitorVolume
        self.monitorEngine = engine
        self.monitorPlayerNode = player
    }

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
            try monitorPlayerNode.playAudio()
            monitorRunning = true
            let outFormat = monitorEngine.outputNode.outputFormat(forBus: 0)
            print("AudioInputChannel[\(label)]: monitor engine started — outputNode format=\(outFormat)")
        } catch {
            print("AudioInputChannel[\(label)]: monitor engine start failed: \(error.localizedDescription)")
        }
    }

    /// Stop the monitor engine.
    func stopMonitor() {
        guard monitorRunning else { return }
        monitorPlayerNode.stop()
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
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.handleTap(buf)
        }
        tapInstalled = true

        // 6. Start.
        engine.prepare()
        try engine.start()
        running = true
        tapCallCount = 0
        lock.lock(); deliveredSinceStart = false; lock.unlock()
        print("AudioInputChannel[\(label)]: engine started")
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
            lock.unlock()
            running = false
            return
        }
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Tear down the monitor alongside capture.
        stopMonitor()
        lock.lock()
        pending.removeAll()
        pendingFrameOffset = 0
        pendingFrameCount = 0
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

    private func handleTap(_ inBuf: AVAudioPCMBuffer) {
        lock.lock(); deliveredSinceStart = true; lock.unlock()
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
            let g = gain
            if g != 1.0 {
                for i in 0..<totalSamples { raw[i] *= g }
            }
            // VU meter — RMS + peak over post-gain samples.
            var sumSq: Float = 0
            for i in 0..<totalSamples {
                let s = raw[i]
                sumSq += s * s
                let a = s < 0 ? -s : s
                if a > peak { peak = a }
            }
            rms = totalSamples > 0 ? (sumSq / Float(totalSamples)).squareRoot() : 0
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
        if monitorRunning,
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
            monitorPlayerNode.scheduleBuffer(monitorBuf, completionHandler: nil)
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

        var produced: AVAudioFrameCount = 0
        var destIdx = 0  // sample index (interleaved, so frame*kMixerChannels)

        while produced < frames, let buf = pending.first {
            let availableInBuf = buf.frameLength - pendingFrameOffset
            let want = frames - produced
            let take = min(availableInBuf, want)
            if take == 0 { break }

            if let raw = buf.floatChannelData?.pointee {
                let srcStart = Int(pendingFrameOffset) * Int(kMixerChannels)
                let count = Int(take) * Int(kMixerChannels)
                // Sum src → dest
                for i in 0..<count {
                    dest[destIdx + i] += raw[srcStart + i]
                }
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

        framesPulledByMixer &+= Int(produced)
        if produced < frames {
            zeroFillEvents &+= 1
            primed = false
        }
        return produced
    }

    // MARK: - Stats

    func snapshot() -> AudioInputChannelStats {
        lock.lock()
        let pushed = convertedFramesPushed
        let pulled = framesPulledByMixer
        let zf = zeroFillEvents
        let trimmed = trimmedFrames
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

    init(channels: [AudioInputChannel],
         outputFormat: AVAudioFormat = makeMixerFormat(),
         chunkFrames: AVAudioFrameCount = kMixerChunkFrames) {
        self.channels = channels
        self.outputFormat = outputFormat
        self.chunkFrames = chunkFrames
    }

    func channel(at index: Int) -> AudioInputChannel? {
        channels.indices.contains(index) ? channels[index] : nil
    }

    var allChannels: [AudioInputChannel] { channels }

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
        for ch in channels { ch.stop() }
        running = false
        startClockTime = .invalid  // reset for the next start()
    }

    // MARK: - Tick → mix → emit

    private func tick() {
        guard running else { return }
        ticks &+= 1

        let frames = chunkFrames
        let sampleCount = Int(frames) * Int(kMixerChannels)

        // Working buffer, zeroed.
        var working = [Float](repeating: 0, count: sampleCount)
        var anyChannelActive = false

        working.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for ch in channels where ch.enabled && ch.running {
                anyChannelActive = true
                _ = ch.pull(intoSummed: base, frames: frames)
            }
        }

        // If no channel is enabled+running, emit silence (still
        // monotonic — keeps the audio track aligned with video).
        // If anyChannelActive is false but we're "running", that's
        // most likely a brief startup window; emit silence too.
        _ = anyChannelActive

        // Wrap in CMSampleBuffer.
        guard let fmt = formatDescription else { return }
        guard let sb = makeSampleBuffer(samples: working, frameCount: Int(frames), format: fmt) else { return }
        mixedFramesEmitted &+= Int(frames)
        sampleClock &+= Int64(frames)

        onMixedSampleBuffer?(sb)
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
            channels: channels.map { $0.snapshot() }
        )
    }
}
