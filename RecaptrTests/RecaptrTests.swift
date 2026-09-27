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

struct FinalCutMarkersTests {

    /// Markers snap to whole frames and titles are escaped.
    @Test func markersLandOnFrames() {
        let xml = FinalCutMarkers.document(
            movURL: URL(fileURLWithPath: "/tmp/Take & Co.mov"),
            markers: [("Marker 1", 7.61), ("Marker 2", 15.0)],
            width: 3840, height: 2160, fps: 60, duration: 30.12, audioTracks: 2)
        #expect(xml.contains(#"<marker start="457/60s" duration="1/60s" value="Marker 1"/>"#))
        #expect(xml.contains(#"<marker start="900/60s" duration="1/60s" value="Marker 2"/>"#))
        #expect(xml.contains(#"duration="1807/60s""#))
        #expect(xml.contains(#"audioSources="2""#))
        #expect(xml.contains("Take &amp; Co"))
    }

    /// 59.94 fps uses the NTSC frame duration.
    @Test func ntscRateUsesFractionalFrameDuration() {
        let xml = FinalCutMarkers.document(
            movURL: URL(fileURLWithPath: "/tmp/a.mov"), markers: [("Marker 1", 1.0)],
            width: 1920, height: 1080, fps: 59.94, duration: 10, audioTracks: 1)
        #expect(xml.contains(#"frameDuration="1001/60000s""#))
        #expect(xml.contains(#"<marker start="60060/60000s""#))
    }
}

struct FrameRateTests {

    /// 60 fps with jitter and a 1 s dropout is still 60, not 59.94.
    @Test func sixtyWithADropoutStaysSixty() {
        var times: [Double] = []
        var t = 0.0
        for i in 0..<600 {
            if i == 300 { t += 1.0 }  // source dropout
            times.append(t + (i % 2 == 0 ? 0.0012 : -0.0012))  // jitter
            t += 1.0 / 60
        }
        #expect(FinalCutMarkers.frameRate(fromTimes: times) == 60)
    }

    @Test func ntscIsRecognised() {
        let times = (0..<600).map { Double($0) * 1001 / 60000 }
        #expect(FinalCutMarkers.frameRate(fromTimes: times) == 59.94)
    }

    @Test func tooFewFramesGivesNil() {
        #expect(FinalCutMarkers.frameRate(fromTimes: [0, 1.0 / 60]) == nil)
    }
}
