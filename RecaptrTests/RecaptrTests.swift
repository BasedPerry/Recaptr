//
//  RecaptrTests.swift
//  RecaptrTests
//

import Testing
import Foundation
@testable import Recaptr

struct PeakLimiterTests {

    /// Stereo sine block at `dbfs`, `frames` long.
    private func sine(dbfs: Float, frames: Int, phase: Int = 0) -> [Float] {
        let amp = powf(10, dbfs / 20)
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let v = amp * sinf(2 * .pi * 440 * Float(f + phase) / 48_000)
            out[2 * f] = v
            out[2 * f + 1] = v
        }
        return out
    }

    private func run(_ limiter: inout PeakLimiter, _ block: inout [Float]) {
        let count = block.count
        block.withUnsafeMutableBufferPointer { limiter.process($0.baseAddress!, sampleCount: count, channels: 2) }
    }

    @Test func quietAudioIsUntouched() {
        var limiter = PeakLimiter()
        let original = sine(dbfs: -12, frames: 1024)
        var block = original
        run(&limiter, &block)
        #expect(block == original)
    }

    @Test func overFullScaleIsHeldUnderTheCeiling() {
        var limiter = PeakLimiter()
        // +6 dBFS: twice full scale, like game audio and a mic peaking
        // together.
        var block = sine(dbfs: 6, frames: 1024)
        run(&limiter, &block)
        let peak = block.map(abs).max() ?? 0
        #expect(peak <= limiter.ceiling + 1e-6)
        #expect(peak > limiter.ceiling * 0.9)  // limited, not muted
    }

    /// Two sources that each fit but together clip: after linked
    /// limiting, playing both tracks together stays under the ceiling
    /// and their balance is unchanged.
    @Test func linkedLimitingKeepsTheSumUnderTheCeiling() {
        var limiter = PeakLimiter()
        var game = sine(dbfs: -2, frames: 1024)   // loud game audio
        var voice = sine(dbfs: -4, frames: 1024)  // voice peaking at the same time
        var sum = zip(game, voice).map { $0 + $1 }
        let count = sum.count
        sum.withUnsafeMutableBufferPointer { s in
            game.withUnsafeMutableBufferPointer { g in
                voice.withUnsafeMutableBufferPointer { v in
                    limiter.processLinked(sum: s.baseAddress!, sources: [g.baseAddress!, v.baseAddress!],
                                          sampleCount: count, channels: 2)
                }
            }
        }
        let playedTogether = zip(game, voice).map { abs($0 + $1) }.max() ?? 0
        #expect(playedTogether <= limiter.ceiling + 1e-5)
        // Balance preserved: voice stays -2 dB relative to the game.
        let ratio = (voice.map(abs).max() ?? 0) / (game.map(abs).max() ?? 1)
        #expect(abs(20 * log10f(ratio) - (-2)) < 0.1)
    }

    @Test func gainRecoversAfterAPeak() {
        var limiter = PeakLimiter()
        var loud = sine(dbfs: 6, frames: 1024)
        run(&limiter, &loud)
        #expect(limiter.gain < 0.5)
        // ~0.5 s of quiet audio afterwards.
        for i in 0..<24 {
            var quiet = sine(dbfs: -20, frames: 1024, phase: i * 1024)
            run(&limiter, &quiet)
        }
        #expect(limiter.gain > 0.95)
    }
}
