//
//  SystemAudioMonitor.swift
//  Recaptr
//
//  Live monitor for screen and window captures. SCStream's system
//  audio goes straight to the recorder and never passes through the
//  AudioMixer, so the mic-channel monitor can't hear it. This plays
//  the same SCStream buffers through a small output-only engine,
//  following the same monitor toggle and volume as the mic monitor.
//
//  Notes:
//    - No feedback loop: the stream is configured with
//      `excludesCurrentProcessAudio`, so what this plays is not
//      captured again.
//    - The engine is rebuilt on every enable so its output binds to
//      the current default output device (same reason as the mic
//      monitor in AudioMixer).
//    - Latency is bounded. SCStream and the output device run on
//      different clocks, so over a long session scheduled audio can
//      pile up. When more than `maxQueuedSeconds` is waiting, incoming
//      buffers are skipped until the queue drains.
//

import Foundation
import AVFoundation
import CoreMedia

nonisolated final class SystemAudioMonitor: @unchecked Sendable {

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var enabled = false
    private var volume: Float = 1.0

    /// Frames scheduled on the player but not yet played.
    private var queuedFrames: Int = 0
    private let maxQueuedSeconds: Double = 0.15

    private var configObserver: NSObjectProtocol?

    /// Buffers skipped to keep latency bounded. Diagnostic only.
    private(set) var skippedBuffers: Int = 0

    // MARK: - Controls (main thread)

    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        let old = on ? nil : detachLocked()
        lock.unlock()
        Self.stop(old)
    }

    func setVolume(_ value: Float) {
        lock.lock()
        volume = value
        engine?.mainMixerNode.outputVolume = value
        lock.unlock()
    }

    /// Stop playback and release the engine. Called when the screen
    /// preview stops.
    func stop() {
        lock.lock()
        let old = detachLocked()
        lock.unlock()
        Self.stop(old)
    }

    // MARK: - Feed (SCStream audio queue)

    /// Schedule one SCStream audio buffer for playback. Cheap no-op
    /// while the monitor is off.
    func feed(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let bufferFormat = AVAudioFormat(formatDescription: desc) else { return }

        lock.lock()
        guard enabled else { lock.unlock(); return }
        // The stream's format changed: drop the old engine (stopped
        // outside the lock) and build a new one below.
        var old: (AVAudioEngine, AVAudioPlayerNode?)?
        if engine != nil, format != bufferFormat {
            old = detachLocked()
        }
        lock.unlock()
        Self.stop(old)

        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        if engine == nil {
            guard startLocked(format: bufferFormat) else { return }
        }
        guard let player, let format else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        let maxQueued = Int(maxQueuedSeconds * format.sampleRate)
        if queuedFrames + frames > maxQueued {
            skippedBuffers &+= 1
            return
        }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return }

        queuedFrames += frames
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames = max(0, self.queuedFrames - frames)
            self.lock.unlock()
        }
    }

    // MARK: - Engine lifecycle

    private func startLocked(format: AVAudioFormat) -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = volume
            engine.prepare()
            try engine.start()
            try player.playAudio()
        } catch {
            print("SystemAudioMonitor: start failed: \(error.localizedDescription)")
            return false
        }
        self.engine = engine
        self.player = player
        self.format = format
        self.queuedFrames = 0
        // Output device changed: macOS stops this engine. Drop it; the
        // next buffer rebuilds it on the new default output.
        configObserver.map { NotificationCenter.default.removeObserver($0) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            print("SystemAudioMonitor: output changed, rebuilding")
            self.lock.lock()
            let old = self.detachLocked()
            self.lock.unlock()
            Self.stop(old)
        }
        print("SystemAudioMonitor: started — \(format)")
        return true
    }

    /// Detach the current engine so the caller can stop it after
    /// releasing the lock. Stopping a player fires its completion
    /// handlers, which take the lock, so stopping while holding it
    /// could deadlock.
    private func detachLocked() -> (AVAudioEngine, AVAudioPlayerNode?)? {
        guard let engine else { return nil }
        let detached = (engine, player)
        self.engine = nil
        self.player = nil
        self.format = nil
        self.queuedFrames = 0
        return detached
    }

    private static func stop(_ detached: (AVAudioEngine, AVAudioPlayerNode?)?) {
        guard let (engine, player) = detached else { return }
        player?.stop()
        engine.stop()
    }
}
