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
