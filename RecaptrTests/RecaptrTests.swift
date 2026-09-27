//
//  RecaptrTests.swift
//  RecaptrTests
//

import Testing
import Foundation
import CoreMedia
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

struct DriftPacerTests {

    /// 31 ppm over 60 s of 1024-frame pulls drops ~89 frames, evenly.
    @Test func fastDeviceDropsAtItsRate() {
        var pacer = DriftPacer()
        let pulls = 60 * 48_000 / 1024
        var drops = 0
        var lastDrop = -1
        var minGap = Int.max
        for i in 0..<pulls where pacer.next(frames: 1024, ppm: 31) == 1 {
            drops += 1
            if lastDrop >= 0 { minGap = min(minGap, i - lastDrop) }
            lastDrop = i
        }
        #expect(abs(drops - Int(60 * 48_000 * 31e-6)) <= 1)
        #expect(minGap >= 25)  // spread out, not bunched
    }

    @Test func slowDeviceRepeats() {
        var pacer = DriftPacer()
        let results = (0..<10_000).map { _ in pacer.next(frames: 1024, ppm: -20) }
        #expect(results.allSatisfy { $0 <= 0 })
        #expect(results.filter { $0 == -1 }.count == Int(10_000 * 1024 * 20e-6))
    }

    @Test func exactClockDoesNothing() {
        var pacer = DriftPacer()
        #expect((0..<10_000).allSatisfy { _ in pacer.next(frames: 1024, ppm: 0) == 0 })
    }
}

struct ScreenResolutionTests {

    @Test func autoKeepsA4KDisplay() {
        let d = ScreenResolution.auto.fit(CGSize(width: 3840, height: 2160))
        #expect(d.width == 3840 && d.height == 2160)
    }

    @Test func capsScaleDownKeepingAspect() {
        let d = ScreenResolution.fhd.fit(CGSize(width: 3840, height: 2160))
        #expect(d.width == 1920 && d.height == 1080)
        // A 5K display fits inside the 4K box.
        let five = ScreenResolution.auto.fit(CGSize(width: 5120, height: 2880))
        #expect(five.width == 3840 && five.height == 2160)
    }

    @Test func windowsKeepTheirShapeWithEvenSizes() {
        let d = ScreenResolution.auto.fit(CGSize(width: 3840, height: 2122))
        #expect(d.width == 3840 && d.height == 2122)
        let odd = ScreenResolution.qhd.fit(CGSize(width: 1001, height: 777))
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
        #expect(odd.width == 1000 || odd.width == 1002)  // never upscaled
    }

    @Test func portraitUsesTheLongSide() {
        let d = ScreenResolution.fhd.fit(CGSize(width: 2160, height: 3840))
        #expect(d.width == 1080 && d.height == 1920)
    }
}

struct SessionNamingTests {

    @Test func sanitizeStripsPathCharacters() {
        #expect(SessionNaming.sanitize("  Fire/Emblem: Three   Houses ") == "Fire-Emblem- Three Houses")
        #expect(SessionNaming.sanitize("..hidden") == "hidden")
    }

    @Test func episodeNumberFollowsExistingFiles() {
        let files = ["Fire Emblem – Ep 1 – Start.mov", "Fire Emblem – Ep 3.mov", "Fire Emblem – Ep 3.fcpxml",
                     "Other – Ep 9.mov", "Fire Emblem – Chapter 5.mov"]
        #expect(SessionNaming.nextEpisodeNumber(existing: files, series: "Fire Emblem") == 4)
        #expect(SessionNaming.nextEpisodeNumber(existing: [], series: "Fire Emblem") == 1)
    }

    @Test func typedEpisodeWinsOverGenerated() {
        #expect(SessionNaming.episode(typed: "Chapter 5", number: 4, generatedTitle: "Fortuna Falls") == "Chapter 5")
        #expect(SessionNaming.episode(typed: " ", number: 4, generatedTitle: "Fortuna Falls") == "Ep 4 – Fortuna Falls")
        #expect(SessionNaming.episode(typed: "", number: 4, generatedTitle: nil) == "Ep 4")
    }

    @Test func uniqueNamesDontOverwrite() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/A – Ep 1.mov", "/tmp/x/A – Ep 1 (2).mov"]
        let url = SessionNaming.uniqueURL(in: folder, base: "A – Ep 1", ext: "mov") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "A – Ep 1 (3).mov")
    }

    @Test func cleanTrimsAndCaps() {
        #expect(MarkerNamer.clean("\"Fortuna Falls!\"", maxWords: 6) == "Fortuna Falls")
        #expect(MarkerNamer.clean("one two three four five six seven", maxWords: 3) == "one two three")
    }
}

import AVFoundation

struct TranscriberTests {

    /// Speak a sentence with the system voice into a file, then run it
    /// through the same on-device transcriber the marker namer uses.
    @Test(.timeLimit(.minutes(3))) func transcribesSpeech() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-test-\(UUID()).caf")
        try await SpeechFile.write("Fortuna is finally down. Heading for the east gate now.", to: url)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let duration = try await asset.load(.duration).seconds
        let transcriber = try #require(await Transcriber.make(), "speech model unavailable")
        let text = await transcriber.transcribe(asset: asset, track: track, from: 0, duration: duration) ?? ""
        print("TranscriberTests heard: \(text)")
        #expect(text.localizedCaseInsensitiveContains("gate"))
    }
}

/// Renders speech to an audio file with AVSpeechSynthesizer.
@MainActor
enum SpeechFile {
    static func write(_ text: String, to url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        var file: AVAudioFile?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            synthesizer.write(AVSpeechUtterance(string: text)) { buffer in
                guard !done, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    done = true
                    cont.resume()
                    return
                }
                do {
                    if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                    try file?.write(from: pcm)
                } catch {
                    done = true
                    cont.resume(throwing: error)
                }
            }
        }
        _ = synthesizer
    }
}
