//
//  AudioMixer.swift
//  Recaptr
//
//  Phase 4.5 (2026-05-09 evening). Multi-source audio capture +
//  per-source gain + single AAC track output, per locked decision #2:
//  "Single mixed audio track, per-source pre-record volume."
//
//  Architecture
//  ─────────────
//  Each AudioInputChannel owns its own AVAudioEngine, bound to a
//  specific input device via Core Audio's
//  kAudioOutputUnitProperty_CurrentDevice. The engine's input node
//  has a tap installed at the device's native format. The tap
//  callback runs the buffer through a cached AVAudioConverter into
//  the canonical mixer format (48 kHz / Stereo / Float32 / interleaved),
//  applies the channel gain in place, and pushes the converted
//  buffer onto the channel's serial queue, protected by mixerLock.
//
//  The AudioMixer runs a DispatchSourceTimer at ~21.3 ms cadence
//  (1024 frames @ 48 kHz). Each tick pulls 1024 frames from each
//  enabled channel, summing into a working buffer (zero-fill if a
//  channel is starved), wraps the sum in a CMSampleBuffer with a
//  monotonically-increasing PTS at 48 kHz timescale, and hands it
//  to onMixedSampleBuffer (Recorder.appendAudio).
//
//  Pre-record lock
//  ───────────────
//  Channel configuration (device, gain, enabled) is intended to be
//  set BEFORE start(). The mixer's start()/stop() calls are made by
//  MainViewModel around the recording lifecycle. The UI disables
//  the channel controls while isRecording is true.
//
//  Phase 4.6 additions (2026-05-09 evening, follow-on):
//   • Per-channel VU (RMS smoothed + peak in dBFS) computed in the
//     tap, surfaced via AudioInputChannelStats. ContentView renders
//     a small meter next to each channel's gain slider.
//   • Verbose engine-startup logging — UID resolution, post-bind
//     device read-back, native format dump — so a "no audio in file"
//     symptom shows its source in the Xcode console immediately.
//   • Read-back helper `currentEngineInputDeviceID(engine:)` that
//     verifies the AUHAL actually bound to the device we asked for
//     (the engine can quietly fall back to the system default).
//
//  Phase 4.7.1 fixes (2026-05-09 night):
//   • PTS now anchored to the host time clock (CMClockGetHostTimeClock).
//     Previously the mixer used sampleClock/48k starting at 0, which
//     put audio PTSes in a different time domain than AVCaptureSession's
//     video PTSes (host time). Result: when video happened to win
//     the dispatch race to writerQueue, it anchored the session at
//     a host-time value (~12,345 s), then every audio buffer's
//     mixer-time PTS (0–135 s) landed before that anchor and got
//     dropped. Brandon's 02:15 recording showed `drop(pre)=8,577/8,944`
//     — 96 % of audio buffers rejected. Fix: pts = startClockTime +
//     sampleClock/48000, where startClockTime is captured from the
//     host clock at AudioMixer.start().
//   • Tap-firing diagnostics: `handleTap` logs first call + every
//     500th call so we can see in the Xcode console whether the
//     tap is firing steadily or stalling.
//
//  Phase 4.7.3 fix (2026-05-09 night, the final audio bug):
//   • The Phase 4.7.1 diagnostic showed the tap was firing 2,500+
//     times — but `push=4800` (one tap-call worth of frames) for
//     the entire recording. The bug: handleTap's AVAudioConverter
//     callback returned `.endOfStream` when our single buffer had
//     been consumed, which tells the converter "the stream is
//     finished forever." After the first tap call's conversion,
//     the converter went into a permanently-drained state and
//     subsequent convert() calls produced 0 output frames. The
//     `guard outBuf.frameLength > 0` then dropped every buffer
//     silently. Fix: signal `.noDataNow` instead — tells the
//     converter to drain the input we just gave it but stay alive
//     for future calls. This was the actual final piece. After
//     phase 4.6.5 (audioanalyticsd) and 4.7.1 (PTS clock), this is
//     what unlocked real audio data flowing into the file.
//
//  Phase 4.7.4 fix (2026-05-09 night, multi-source resilience):
//   • macOS HAL refuses two simultaneous AVAudioEngine input
//     bindings to different physical devices. Channel 2's
//     engine.start() throws kAudioServerStopErr (1937010544 =
//     "stop"). Previously this throw propagated out of
//     AudioMixer.start() before the timer was scheduled, leaving
//     Channel 1's already-running engine orphaned (running but no
//     mixer pulling from it). The recorder then got hasAudio=false
//     and produced a video-only file even though Channel 1 was
//     still capturing audio. Fix: catch each channel's start()
//     individually, mark per-channel lastError on failure, keep
//     going; mixer succeeds as long as at least one channel
//     started. This is graceful degradation — full multi-source
//     mixing requires a Core Audio aggregate device (Phase 4.8).
//
//  Limitations (deferred to Phase 4.8+):
//   • No system-loopback capture for game audio (BlackHole / virtual
//     audio device required — Apple does not expose loopback of
//     arbitrary audio outputs in shipping macOS Tahoe).
//   • Two-channel cap in UI (the architecture supports N channels).
//   • Channel timing alignment is "drop or zero-fill", not phase-
//     accurate cross-device sync.
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
    var lastError: String?
    /// Phase 4.6 — RMS over the last converted buffer, in dBFS
    /// (-inf .. 0). Smoothed with a simple low-pass for a stable
    /// VU-style display.
    var rmsDbfs: Float = -120.0
    /// Phase 4.6 — peak sample magnitude over the last converted
    /// buffer, in dBFS.
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
private let kMixerSampleRate: Double = 48_000
private let kMixerChannels: AVAudioChannelCount = 2
private let kMixerChunkFrames: AVAudioFrameCount = 1024

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
final class AudioInputChannel: @unchecked Sendable {

    let label: String
    private let outputFormat: AVAudioFormat
    /// Phase 4.9.1 — non-interleaved standard format used for the
    /// monitor engine's player→mixer connection. AVAudioEngine's
    /// mixer nodes reject interleaved formats on connections (the
    /// `outputFormat` we use for CMSampleBuffer construction is
    /// interleaved, so we need a separate format here).
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
    private(set) var convertedFramesPushed: Int = 0
    private(set) var framesPulledByMixer: Int = 0
    private(set) var zeroFillEvents: Int = 0
    private(set) var lastError: String?

    // Phase 4.6 — VU meter. Smoothed RMS / peak in dBFS, updated each
    // tap callback. Read by snapshot() under lock.
    private var smoothedRmsDbfs: Float = -120.0
    private var lastPeakDbfs: Float = -120.0

    // Phase 4.7.1 — tap-firing diagnostic. Brandon's last test had
    // push=4800 (only 100 ms) over a 3-minute recording, suggesting
    // the tap fires briefly and stalls. These counters log to the
    // Xcode console so we can see exactly when the cliff happens.
    private var tapCallCount: Int = 0

    // Phase 4.9 — live audio monitoring. A separate AVAudioEngine
    // dedicated to OUTPUT plays each converted buffer back to the
    // system default output device. Output-only engines don't hit
    // the multi-input HAL conflict that killed multi-source capture.
    // Latency is roughly tap-buffer (~21–100 ms) + AVAudioPlayerNode
    // scheduling (~10–20 ms) — fine for game-capture monitoring.
    //
    // Phase 4.9.2 — these are now `var` because AVAudioEngine binds
    // its outputNode to the system default output at engine-start
    // time and does NOT follow later changes in Sound settings. We
    // rebuild both fresh on every monitor toggle-on (see
    // buildMonitorEngine() + startMonitorIfNeeded()) so the engine
    // always binds to the user's *current* output choice.
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

    init(label: String, outputFormat: AVAudioFormat) {
        self.label = label
        self.outputFormat = outputFormat
        // Phase 4.9.1 — standardFormatWithSampleRate: produces a
        // non-interleaved Float32 format that AVAudioEngine's mixer
        // nodes accept on their bus connections. We de-interleave
        // each outBuf into a buffer of this format before scheduling
        // it on the monitor player node (see handleTap).
        self.monitorFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputFormat.sampleRate,
            channels: outputFormat.channelCount
        ) ?? outputFormat

        // Phase 4.9 — wire the monitor graph: player → mainMixer → output.
        // No input bus on this engine — it only renders to the system
        // default output device.
        //
        // Phase 4.9.2 — the initial-wire is done via buildMonitorEngine()
        // so the (re)build path is the single source of truth for wiring.
        // The engine constructed here is throwaway — it'll be replaced
        // the first time the user toggles Monitor ON, ensuring the
        // outputNode binds to the *then-current* default output device
        // rather than whatever was selected when the app launched.
        buildMonitorEngine()
    }

    /// Phase 4.9.2 — (re)build the monitor engine + player node from
    /// scratch and re-wire the graph. AVAudioEngine.outputNode binds
    /// to whatever the system default output device is at engine-start
    /// time; once bound, it does NOT follow later Sound-settings
    /// changes. So `startMonitorIfNeeded()` calls this on every
    /// toggle-on, throwing away the previous engine. The fresh engine
    /// binds to whatever the user's current default output is —
    /// speakers, headphones, AirPods, an HDMI device, whatever.
    ///
    /// This is a workaround for the per-toggle case. A permanent fix
    /// (listen for kAudioHardwarePropertyDefaultOutputDevice changes
    /// and rebuild transparently) is deferred to the Audio + Video
    /// monitor unification work that lands with the UI redesign.
    private func buildMonitorEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: monitorFormat)
        engine.mainMixerNode.outputVolume = monitorVolume
        self.monitorEngine = engine
        self.monitorPlayerNode = player
    }

    /// Phase 4.9 — start the monitor engine if monitorEnabled is set.
    /// Called by AudioMixer after a successful capture engine start.
    /// Idempotent: safe to call when already running.
    ///
    /// Phase 4.9.2 — every toggle-on rebuilds the engine via
    /// buildMonitorEngine() so the outputNode re-binds to the
    /// *current* system default output device. Without this, the
    /// engine remains bound to whatever default existed at app
    /// launch, even if the user later switches outputs in System
    /// Settings, producing silent monitor playback on the wrong
    /// device. Logs the bound output format on success so we can
    /// confirm the rebind worked.
    func startMonitorIfNeeded() {
        guard monitorEnabled, !monitorRunning else { return }
        buildMonitorEngine()
        do {
            monitorEngine.prepare()
            try monitorEngine.start()
            monitorPlayerNode.play()
            monitorRunning = true
            let outFormat = monitorEngine.outputNode.outputFormat(forBus: 0)
            print("AudioInputChannel[\(label)]: monitor engine started — outputNode format=\(outFormat)")
        } catch {
            print("AudioInputChannel[\(label)]: monitor engine start failed: \(error.localizedDescription)")
        }
    }

    /// Phase 4.9 — stop the monitor engine.
    func stopMonitor() {
        guard monitorRunning else { return }
        monitorPlayerNode.stop()
        monitorEngine.stop()
        monitorRunning = false
    }

    /// Phase 4.9 — toggle monitor live without restarting capture.
    /// Called by MainViewModel via Combine when the UI toggle changes.
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
        guard let deviceUID = deviceUniqueID else {
            throw CaptureError.configurationFailed("\(label): no device selected")
        }

        // 1. Find Core Audio device ID for the AVCaptureDevice uniqueID.
        let coreAudioID = try Self.audioDeviceID(forUID: deviceUID)
        print("AudioInputChannel[\(label)]: resolved UID '\(deviceUID)' → CoreAudio device \(coreAudioID)")

        // 2. Bind the engine's input audio unit to that device.
        try Self.setEngineInputDevice(engine: engine, deviceID: coreAudioID)
        // Phase 4.6 verify: read it back. If the engine quietly fell
        // back to the default input, surface that — otherwise we'd
        // capture from the wrong device with no warning.
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

        // 5. Install tap.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.handleTap(buf)
        }
        tapInstalled = true

        // 6. Start.
        engine.prepare()
        try engine.start()
        running = true
        tapCallCount = 0  // Phase 4.7.1 — fresh diagnostic count.
        print("AudioInputChannel[\(label)]: engine started")
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Phase 4.9 — tear down monitor along with capture.
        stopMonitor()
        lock.lock()
        pending.removeAll()
        pendingFrameOffset = 0
        pendingFrameCount = 0
        lock.unlock()
        running = false
    }

    /// Phase 4.7.4 — record a start() failure without re-throwing,
    /// so other channels can keep running. Called by AudioMixer when
    /// a per-channel start throws.
    func recordStartFailure(_ message: String) {
        lock.lock()
        lastError = message
        lock.unlock()
        running = false
    }

    // MARK: - Tap → converted buffer → pending queue

    private func handleTap(_ inBuf: AVAudioPCMBuffer) {
        // Phase 4.7.1 — tap-firing diagnostic. First call + every
        // 500th gets logged (a tap calling at 48k/1024 ≈ 47 Hz means
        // ~1 log per 10 seconds). If the count plateaus in the
        // console, we know exactly when the tap stopped firing.
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
        // Phase 4.7.3 — use .noDataNow (NOT .endOfStream) to signal
        // "no more input right now." `.endOfStream` permanently
        // retires the converter; after the first tap call's
        // conversion the converter would refuse to produce any more
        // output, even though the tap keeps firing with fresh data.
        // That manifested as `push=4800` (one tap-call worth of
        // frames) for the entire recording while the tap callback
        // fired thousands of times. `.noDataNow` lets the converter
        // drain the input we just gave it but stay alive for the
        // next call.
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
            // Phase 4.6 VU — RMS + peak over post-gain samples.
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

        // Phase 4.9 — live monitor playback. Phase 4.9.1: outBuf is
        // interleaved (required for CMSampleBuffer construction) but
        // AVAudioEngine's mixer nodes need non-interleaved (planar)
        // PCM. De-interleave into a monitorFormat buffer and schedule
        // that on the player node. AVAudioPlayerNode copies buffer
        // contents internally so the source can be released after.
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

    /// Pull up to `frames` frames into `dest`, summing into existing
    /// content. `dest` is interleaved Float32 stereo
    /// (kMixerChannels samples per frame). Returns the number of
    /// frames actually summed in (the rest is unchanged — caller
    /// should zero-fill at allocation time, this only adds).
    @discardableResult
    func pull(intoSummed dest: UnsafeMutablePointer<Float>, frames: AVAudioFrameCount) -> AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }

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
        }
        return produced
    }

    // MARK: - Stats

    func snapshot() -> AudioInputChannelStats {
        lock.lock()
        let pushed = convertedFramesPushed
        let pulled = framesPulledByMixer
        let zf = zeroFillEvents
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
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw CaptureError.configurationFailed("Engine has no input audioUnit")
        }
        var devID = deviceID
        let st = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard st == noErr else {
            throw CaptureError.configurationFailed("AudioUnitSetProperty(CurrentDevice): \(st)")
        }
    }

    /// Phase 4.6 — read back the audio unit's current device, used
    /// after setEngineInputDevice() to verify the bind actually took.
    static func currentEngineInputDeviceID(engine: AVAudioEngine) throws -> AudioDeviceID {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw CaptureError.configurationFailed("Engine has no input audioUnit")
        }
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            &size
        )
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

    /// Phase 4.7.1 — host clock time captured at start(). Mixer PTS
    /// is computed as startClockTime + sampleClock/sampleRate so it
    /// shares the time domain with AVCaptureSession's video PTSes.
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
        channels.contains { $0.enabled && $0.deviceUniqueID != nil }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }

        // 1. Build CM format description (lazy on first emission would
        // also work, but doing it up front surfaces format errors at
        // start time instead of mid-stream).
        formatDescription = try Self.makeFormatDescription(from: outputFormat)

        // 2. Start every enabled channel that has a device.
        // Phase 4.7.4 — graceful per-channel start. Two simultaneous
        // AVAudioEngine input bindings on macOS produce a HAL
        // conflict (kAudioServerStopErr = 1937010544 = "stop"); the
        // second engine.start() throws. Previously we propagated
        // that throw out of AudioMixer.start, which killed the
        // already-running Channel 1's audio path because the mixer
        // never reached its timer-resume step. Now we record the
        // per-channel failure and keep going — mixer succeeds as
        // long as at least one channel started.
        var anyStarted = false
        for ch in channels where ch.enabled && ch.deviceUniqueID != nil {
            do {
                try ch.start()
                anyStarted = true
                // Phase 4.9 — fire up the monitor engine if the
                // channel was configured with monitoring on. No-op
                // if monitorEnabled == false.
                ch.startMonitorIfNeeded()
            } catch {
                ch.recordStartFailure(error.localizedDescription)
                print("AudioMixer: channel '\(ch.label)' failed to start: \(error.localizedDescription) — continuing with remaining channels")
            }
        }
        guard anyStarted else {
            throw CaptureError.configurationFailed("No audio channels could start")
        }

        // 3. Reset clocks.
        sampleClock = 0
        mixedFramesEmitted = 0
        ticks = 0
        // Phase 4.7.1 — capture host clock so PTS shares time domain
        // with AVCaptureSession's video frames.
        let hostClock = CMClockGetHostTimeClock()
        startClockTime = CMClockGetTime(hostClock)
        print("AudioMixer: start clock anchored at host time \(CMTimeGetSeconds(startClockTime))s")

        // 4. Schedule the timer. 1024 / 48000 = ~21.3ms.
        let interval = Double(chunkFrames) / outputFormat.sampleRate
        let t = DispatchSource.makeTimerSource(queue: emissionQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        running = true
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for ch in channels { ch.stop() }
        running = false
        startClockTime = .invalid  // Phase 4.7.1 — reset for next start().
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

        // Phase 4.7.1 — PTS in host time domain. startClockTime was
        // captured at start(); add sampleClock-relative offset so
        // each emit is monotonically advancing at exactly 48 kHz.
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
