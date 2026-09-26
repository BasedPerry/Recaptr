//
//  PeakLimiter.swift
//  Recaptr
//
//  Keeps mixed audio below full scale. Summing game audio and a
//  commentary mic can peak over 0 dBFS (a 2026-09-26 take hit +1.1),
//  which clips when the file is played. The limiter leaves anything
//  under the ceiling untouched and turns peaks down smoothly: instant
//  attack per block, release back to unity over ~150 ms, and a hard
//  clamp underneath so no sample can exceed the ceiling.
//
//  Operates on interleaved Float32 blocks in place. One instance per
//  output track, since the gain state is per stream.
//

import Foundation

nonisolated struct PeakLimiter {
    /// Output never exceeds this (linear). -1 dBFS leaves headroom for
    /// AAC encoding overshoot.
    let ceiling: Float
    /// Per-sample recovery toward unity gain.
    private let releaseCoefficient: Float
    /// Gain applied at the end of the previous block.
    private(set) var gain: Float = 1

    init(ceilingDbfs: Float = -1, releaseSeconds: Double = 0.15, sampleRate: Double = 48_000) {
        ceiling = powf(10, ceilingDbfs / 20)
        releaseCoefficient = Float(exp(-1 / (releaseSeconds * sampleRate)))
    }

    /// Limit `sampleCount` interleaved samples (`channels` per frame).
    mutating func process(_ samples: UnsafeMutablePointer<Float>, sampleCount: Int, channels: Int) {
        guard sampleCount > 0, channels > 0 else { return }

        var peak: Float = 0
        for i in 0..<sampleCount { peak = max(peak, abs(samples[i])) }

        // Gain this block needs so its peak lands on the ceiling.
        let needed: Float = peak > ceiling ? ceiling / peak : 1
        let frames = sampleCount / channels
        let start = gain
        // Attack: reach the needed gain immediately. Release: recover
        // toward unity sample by sample, never above what's needed.
        var g = start
        for f in 0..<frames {
            if needed < g {
                g = needed
            } else {
                g = min(needed, 1 - (1 - g) * releaseCoefficient)
            }
            for c in 0..<channels {
                let idx = f * channels + c
                // Hard clamp as the last line of defense.
                samples[idx] = min(max(samples[idx] * g, -ceiling), ceiling)
            }
        }
        gain = g
    }
}
