//
//  LevelTracker.swift
//  Recaptr
//
//  Levels for audio that bypasses the mixer (SCStream system audio with
//  no mic). Fed on the audio queue, read by the UI.
//

import Foundation
import CoreMedia
import AVFoundation

nonisolated final class LevelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var rmsDbfs: Float = -120
    private var peakDbfs: Float = -120
    private var updatedAt = Date.distantPast

    /// Measure one Float32 PCM sample buffer.
    func feed(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let format = AVAudioFormat(formatDescription: desc),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        ) == noErr, let data = pcm.floatChannelData else { return }

        var sumSq: Float = 0, peak: Float = 0, n = 0
        let channels = Int(format.channelCount)
        // Interleaved: one buffer of frames x channels samples.
        // Planar: one buffer of `frames` samples per channel.
        let buffers = format.isInterleaved ? 1 : channels
        let count = format.isInterleaved ? frames * channels : frames
        for b in 0..<buffers {
            for i in 0..<count {
                let v = data[b][i]
                sumSq += v * v
                peak = max(peak, abs(v))
                n += 1
            }
        }
        let rms = n > 0 ? 10 * log10f(sumSq / Float(n) + 1e-12) : -120
        let pk = 20 * log10f(peak + 1e-12)

        lock.lock()
        rmsDbfs = 0.4 * max(rms, -120) + 0.6 * rmsDbfs
        peakDbfs = max(pk, -120)
        updatedAt = Date()
        lock.unlock()
    }

    /// Current levels, or nil if nothing arrived in the last half
    /// second (source stopped).
    func levels() -> (rms: Float, peak: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(updatedAt) < 0.5 else { return nil }
        return (rmsDbfs, peakDbfs)
    }
}
