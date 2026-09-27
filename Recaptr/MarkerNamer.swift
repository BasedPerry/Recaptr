//
//  MarkerNamer.swift
//  Recaptr
//
//  Names clip markers, and titles the episode, with Apple Intelligence
//  once a recording has stopped. For each marker the on-device model
//  sees the frame at that moment and what was said on the mic from
//  20 s before to 3 s after, and returns a short label ("Fortuna Phase
//  Two, Barely"). The labels then give the episode a title when the
//  user left it blank.
//
//  Everything runs on the Mac: Foundation Models' on-device model
//  (image input is new in macOS 27) and SpeechAnalyzer for the
//  transcript. It runs after the take, never during it, so it can't
//  compete with capture. Without Apple Intelligence it does nothing
//  and markers keep their numbers.
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
            let frame = await frameImage(asset, at: seconds)
            var said: String?
            if let speechTrack, let transcriber {
                said = await transcriber.transcribe(asset: asset, track: speechTrack,
                                                    from: max(0, seconds - transcriptBefore),
                                                    duration: transcriptBefore + transcriptAfter)
            }
            #if DEBUG
            print("MarkerNamer: at \(Int(seconds)) s heard: \(said ?? "(nothing)")")
            #endif
            labels.append(await label(frame: frame, said: said, series: series))
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

    private static func label(frame: CGImage?, said: String?, series: String?) async -> String? {
        guard frame != nil || !(said ?? "").isEmpty else { return nil }
        let session = LanguageModelSession(instructions: BrandVoice.markerInstructions)
        var context = ""
        if let series { context += "Series: \(series)\n" }
        if let said, !said.isEmpty { context += "Said on the mic around this moment: \"\(said)\"\n" }
        context += "Name this moment."
        do {
            let response: LanguageModelSession.Response<MarkerLabel>
            if let frame {
                response = try await session.respond(generating: MarkerLabel.self) {
                    context
                    Attachment(frame).label("The frame at this moment")
                }
            } else {
                response = try await session.respond(to: context, generating: MarkerLabel.self)
            }
            return clean(response.content.title, maxWords: 8)
        } catch {
            print("MarkerNamer: label failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Trim quotes and stray punctuation, cap the word count.
    static func clean(_ text: String, maxWords: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.!")))
        let words = trimmed.split(separator: " ").prefix(maxWords)
        // Title case (brand voice), leaving words that already have
        // capitals ("HP", "iPhone") as they are.
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

    /// The frame at `seconds`, scaled to at most 1280 px (images cost
    /// tokens by size; this is plenty to tell what's on screen).
    private static func frameImage(_ asset: AVURLAsset, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The mic track when the file has per-source tracks ("Mic"),
    /// otherwise the only audio track.
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

    /// Nil when the language isn't supported or its model can't be
    /// installed; labels then come from the frame alone.
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

    /// Decode a stretch of `track` into a temporary file in the
    /// transcriber's preferred format.
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
