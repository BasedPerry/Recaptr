//
//  MonitorLagProbe.swift
//  Recaptr
//
//  Debug-only measurement for UI tests. With monitoring on and the
//  output playing through speakers, the commentary mic hears the
//  monitored game audio. Cross-correlating the game track with the
//  mic track gives the real monitor delay: capture, monitor path,
//  output device, and the air gap to the mic.
//
//  Enabled with `-RecaptrUITesting YES -RecaptrUITestMeasureMonitorLag YES`.
//  The recordings live in the app's container, which test tooling
//  can't read, so the app measures and prints the result itself.
//

#if DEBUG
import AVFoundation
import Accelerate

enum MonitorLagProbe {

    /// Lag of track 2 (mic) behind track 1 (game) in ms, with the
    /// normalised correlation, for several windows of the file.
    static func measure(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.count >= 2,
              let duration = try? await asset.load(.duration).seconds else {
            return "monitor lag: needs two audio tracks"
        }
        var parts: [String] = []
        for start in stride(from: 4.0, to: max(4.0, duration - 6), by: 5.0) {
            guard let game = mono(asset, tracks[0], start, 4),
                  let mic = mono(asset, tracks[1], start, 4) else { continue }
            let (lag, corr) = bestLag(game, mic, maxLag: 24_000)
            parts.append(String(format: "%.0fs:%+.1fms(%.2f)", start, Double(lag) / 48, corr))
        }
        return "monitor lag: " + parts.joined(separator: " ")
    }

    /// Video frame spacing: frame count, gaps over 25 ms with their
    /// times, and the longest gap.
    static func videoGaps(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return "video gaps: unreadable" }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return "video gaps: unreadable" }
        var times: [Double] = []
        while let buffer = out.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds) }
        }
        times.sort()
        var gaps: [String] = []
        var longest = 0.0
        for i in 1..<max(1, times.count) {
            let gap = times[i] - times[i - 1]
            longest = max(longest, gap)
            if gap > 0.025 { gaps.append(String(format: "%.0fms@%.2fs", gap * 1000, times[i - 1] - (times.first ?? 0))) }
        }
        return String(format: "video gaps: frames=%d longest=%.0fms gaps>25ms=%d ", times.count, longest * 1000, gaps.count)
            + gaps.prefix(12).joined(separator: " ")
    }

    /// Share of edge pixels (3 px border of a frame 5 s in) that are
    /// strongly green, to prove the capture outline isn't recorded.
    static func greenEdge(_ url: URL) async -> String {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: 5, preferredTimescale: 600)).image,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return "green edge: no frame"
        }
        let w = image.width, h = image.height, row = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        var edge = 0, green = 0
        for y in 0..<h {
            for x in 0..<w where x < 3 || y < 3 || x >= w - 3 || y >= h - 3 {
                let p = bytes + y * row + x * bpp
                // BGRA or RGBA: green is byte 1 either way.
                let (c0, g, c2) = (Int(p[0]), Int(p[1]), Int(p[2]))
                edge += 1
                if g > 120, g > c0 + 50, g > c2 + 50 { green += 1 }
            }
        }
        return String(format: "green edge: %.1f%% of %d edge pixels", 100 * Double(green) / Double(max(edge, 1)), edge)
    }

    private static func mono(_ asset: AVAsset, _ track: AVAssetTrack, _ start: Double, _ dur: Double) -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: dur, preferredTimescale: 48_000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        reader.add(out)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { f in
                for i in stride(from: 0, to: length / 4 - 1, by: 2) { samples.append((f[i] + f[i + 1]) / 2) }
            }
        }
        return samples
    }

    /// Mic lag behind game, in samples (positive = mic later).
    private static func bestLag(_ game: [Float], _ mic: [Float], maxLag: Int) -> (Int, Float) {
        let n = min(game.count, mic.count) - 2 * maxLag
        guard n > 0 else { return (0, 0) }
        func score(_ lag: Int) -> Float {
            var r: Float = 0
            game.withUnsafeBufferPointer { g in
                mic.withUnsafeBufferPointer { m in
                    vDSP_dotpr(g.baseAddress! + maxLag, 1, m.baseAddress! + maxLag + lag, 1, &r, vDSP_Length(n))
                }
            }
            return r
        }
        var best: Float = -.infinity
        var bestLag = 0
        for lag in stride(from: -maxLag, through: maxLag, by: 48) {
            let r = score(lag)
            if r > best { best = r; bestLag = lag }
        }
        for lag in (bestLag - 48)...(bestLag + 48) {
            let r = score(lag)
            if r > best { best = r; bestLag = lag }
        }
        var eg: Float = 0, em: Float = 0
        game.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + maxLag, 1, &eg, vDSP_Length(n)) }
        mic.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + maxLag + bestLag, 1, &em, vDSP_Length(n)) }
        return (bestLag, best / max(1e-12, (eg * em).squareRoot()))
    }
}
#endif
