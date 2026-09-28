//
//  PeakLimiter.swift
//  Recaptr
//
//  Keeps mixed audio under full scale without touching quieter audio.

import Foundation

/// Instant attack per block, ~150 ms release back to unity, and a hard
/// clamp at the ceiling. Works in place on interleaved Float32; one
/// instance per stream since it holds gain state.
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
        processLinked(sum: samples, sources: [], sampleCount: sampleCount, channels: channels)
    }

    /// Linked limiting: gain comes from `sum` and is applied to `sum` and
    /// every source, so per-source tracks that a player sums stay under the
    /// ceiling with their balance unchanged. Each source is also clamped.
    mutating func processLinked(sum samples: UnsafeMutablePointer<Float>,
                                sources: [UnsafeMutablePointer<Float>],
                                sampleCount: Int, channels: Int) {
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
                for src in sources {
                    src[idx] = min(max(src[idx] * g, -ceiling), ceiling)
                }
            }
        }
        gain = g
    }
}
