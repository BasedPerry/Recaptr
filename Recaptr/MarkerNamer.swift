//
//  MarkerNamer.swift
//  Recaptr
//
//  Names markers and titles the episode with the on-device model.
//  Runs after the take, never during capture.
//

import AVFoundation
import FoundationModels
import Speech

@Generable
struct MarkerLabel {
    @Guide(description: "A 2 to 6 word title-case label for the moment")
    var title: String
}

@Generable
struct EpisodeTitle {
    @Guide(description: "A 2 to 5 word title-case episode title")
    var title: String
}

nonisolated enum MarkerNamer {

    /// Seconds of commentary before and after a marker to transcribe.
    static let transcriptBefore = 20.0
    static let transcriptAfter = 3.0

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why naming can't run, for Settings. Nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Try again shortly."
        case .unavailable: return "Apple Intelligence isn't available."
        }
    }

    /// A label per marker (nil where one couldn't be made), in order.
    static func labels(for movURL: URL, markerSeconds: [Double], series: String?) async -> [String?] {
        guard isAvailable, !markerSeconds.isEmpty else { return markerSeconds.map { _ in nil } }
        let asset = AVURLAsset(url: movURL)
        let speechTrack = await commentaryTrack(in: asset)
        let transcriber = await Transcriber.make()

        var labels: [String?] = []
        for seconds in markerSeconds {
            let frames = await informativeFrames(asset, around: seconds)
            var said: String?
            if let speechTrack, let transcriber {
                said = await transcriber.transcribe(asset: asset, track: speechTrack,
                                                    from: max(0, seconds - transcriptBefore),
                                                    duration: transcriptBefore + transcriptAfter)
            }
            #if DEBUG
            print("MarkerNamer: at \(Int(seconds)) s heard: \(said ?? "(nothing)")")
            #endif
            let used = labels.compactMap { $0 }
            var name = await label(frames: frames, said: said, series: series, alreadyUsed: used)
            // The model often ignores "don't repeat". Retry once, then number it.
            if let first = name, used.contains(where: { isNearDuplicate($0, first) }) {
                name = await label(frames: frames, said: said, series: series, alreadyUsed: used, insist: true)
                if let retry = name, used.contains(where: { isNearDuplicate($0, retry) }) {
                    let count = used.filter { isNearDuplicate($0, retry) }.count + 1
                    name = "\(retry) (\(count))"
                }
            }
            labels.append(name)
        }
        return labels
    }

    /// Episode title from the marker labels, or nil.
    static func episodeTitle(fromLabels labels: [String], series: String?) async -> String? {
        guard isAvailable, !labels.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: BrandVoice.episodeInstructions)
        let prompt = """
        \(series.map { "Series: \($0)\n" } ?? "")Moments marked in this episode, in order:
        \(labels.map { "- \($0)" }.joined(separator: "\n"))
        """
        guard let response = try? await session.respond(to: prompt, generating: EpisodeTitle.self) else { return nil }
        return clean(response.content.title, maxWords: 6)
    }

    // MARK: - One marker

    private static func label(frames: [CGImage], said: String?, series: String?,
                              alreadyUsed: [String], insist: Bool = false) async -> String? {
        guard !frames.isEmpty || !(said ?? "").isEmpty else { return nil }
        let session = LanguageModelSession(instructions: BrandVoice.markerInstructions)
        var context = ""
        if let series { context += "Series: \(series)\n" }
        if let said, !said.isEmpty { context += "Heard on the commentary mic just before the marker: \"\(said)\"\n" }
        if !alreadyUsed.isEmpty {
            context += "Names already used in this recording: \(alreadyUsed.joined(separator: "; ")). "
                + "Don't reuse them; if this is the same scene, name what changed.\n"
        }
        if insist {
            context += "Your last name repeated one of those. Give a clearly different name.\n"
        }
        context += "Name this moment."
        let options = GenerationOptions(temperature: insist ? 1.0 : nil)
        do {
            let response: LanguageModelSession.Response<MarkerLabel>
            if frames.count >= 2 {
                response = try await session.respond(generating: MarkerLabel.self, options: options) {
                    context
                    Attachment(frames[0]).label("Just before the marker")
                    Attachment(frames[1]).label("At or just after the marker")
                }
            } else if let frame = frames.first {
                response = try await session.respond(generating: MarkerLabel.self, options: options) {
                    context
                    Attachment(frame).label("The frame at this moment")
                }
            } else {
                response = try await session.respond(to: context, generating: MarkerLabel.self, options: options)
            }
            return clean(response.content.title, maxWords: 8)
        } catch {
            print("MarkerNamer: label failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// True when most words share their first four letters ("Failure" vs "Failed").
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        func stems(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map { String($0.prefix(4)) })
        }
        let x = stems(a), y = stems(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }

    /// Trim quotes and stray punctuation, cap the word count.
    static func clean(_ text: String, maxWords: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.!")))
        let words = trimmed.split(separator: " ").prefix(maxWords)
        // Title case, leaving words that already have capitals ("HP", "iPhone").
        let small: Set<String> = ["a", "an", "and", "at", "for", "in", "of", "on", "or", "the", "to", "vs"]
        let result = words.enumerated().map { index, word -> String in
            let w = String(word)
            guard w == w.lowercased() else { return w }
            if index > 0, small.contains(w) { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    // MARK: - Inputs

    /// The two most detailed of three frames around the marker, in time order.
    /// Flat frames (black, loading screens) are skipped. 960 px keeps two
    /// images within the model's context.
    private static func informativeFrames(_ asset: AVURLAsset, around seconds: Double) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.appliesPreferredTrackTransform = true
        var all: [(time: Double, image: CGImage, detail: Double)] = []
        for offset in [-1.5, 0, 1.5] {
            let t = max(0, seconds + offset)
            guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            all.append((t, image, luminanceDetail(image)))
        }
        #if DEBUG
        print("MarkerNamer: at \(Int(seconds)) s frame detail " + all.map { String(format: "%.3f", $0.detail) }.joined(separator: " "))
        #endif
        let detailed = all.filter { $0.detail >= minimumDetail }
        // All flat: still show a dark scene, but never a truly black frame.
        let pool = detailed.isEmpty ? Array(all.filter { $0.detail >= blackDetail }.sorted { $0.detail > $1.detail }.prefix(1)) : detailed
        return pool.sorted { $0.detail > $1.detail }.prefix(2)
            .sorted { $0.time < $1.time }.map(\.image)
    }

    /// Frames flatter than this (standard deviation of luminance, 0...1)
    /// are skipped as blank.
    static let minimumDetail = 0.03
    /// Below this a frame is effectively black and never shown.
    static let blackDetail = 0.005

    /// Luminance standard deviation on a 32x32 grey thumbnail. Near 0 for flat screens.
    static func luminanceDetail(_ image: CGImage) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 1 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    /// The "Mic" track when tracks are split by source, otherwise the only audio track.
    private static func commentaryTrack(in asset: AVURLAsset) async -> AVAssetTrack? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return nil }
        for track in tracks {
            let items = (try? await track.load(.metadata)) ?? []
            for item in items where item.identifier == .quickTimeUserDataTrackName {
                if (try? await item.load(.stringValue)) == "Mic" { return track }
            }
        }
        return tracks.count == 1 ? tracks[0] : nil
    }
}

// MARK: - Transcription

/// On-device transcription of short stretches of a recording's audio.
nonisolated final class Transcriber: Sendable {
    let locale: Locale
    let format: AVAudioFormat

    private init(locale: Locale, format: AVAudioFormat) {
        self.locale = locale
        self.format = format
    }

    /// Nil when the language or its model is unavailable; labels then use frames only.
    static func make() async -> Transcriber? {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        } catch {
            print("MarkerNamer: speech model unavailable: \(error.localizedDescription)")
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else { return nil }
        return Transcriber(locale: locale, format: format)
    }

    func transcribe(asset: AVAsset, track: AVAssetTrack, from start: Double, duration: Double) async -> String? {
        guard let file = try? writeClip(asset: asset, track: track, from: start, duration: duration) else { return nil }
        defer { try? FileManager.default.removeItem(at: file.url) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> String in
            var text = ""
            do {
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters) + " "
                }
            } catch {}
            return text
        }
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            return nil
        }
        let text = await collector.value.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Decodes a stretch of `track` to a temp file in the transcriber's format.
    private func writeClip(asset: AVAsset, track: AVAssetTrack, from start: Double, duration: Double) throws -> AVAudioFile {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        guard let readFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                             channels: format.channelCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recaptr-speech-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                               into: buffer.mutableAudioBufferList) == noErr else { continue }
            try file.write(from: buffer)
        }
        // Reopen for reading so the analyzer sees the finished file.
        return try AVAudioFile(forReading: url)
    }
}
