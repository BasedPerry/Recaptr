//
//  FinalCutMarkers.swift
//  Recaptr
//
//  Writes an FCPXML 1.11 file (Final Cut 10.6.6+) beside a recording.
//  Markers live here, not in the .mov.
//

import Foundation
import AVFoundation

enum FinalCutMarkers {

    /// Writes `<recording>.fcpxml` when the take has markers or a series.
    /// The event is named after the series so episodes import together.
    @discardableResult
    static func writeIfNeeded(for movURL: URL, markers: [(title: String, seconds: Double)],
                              eventName: String? = nil) async throws -> URL? {
        guard !markers.isEmpty || eventName != nil else { return nil }
        let asset = AVURLAsset(url: movURL)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }

        let size = try await video.load(.naturalSize)
        let fps = try await frameRate(of: video, in: asset)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio).count

        let xml = document(movURL: movURL, markers: markers, width: Int(size.width),
                           height: Int(size.height), fps: fps, duration: duration,
                           audioTracks: audioTracks, eventName: eventName ?? "Recaptr")
        let out = movURL.deletingPathExtension().appendingPathExtension("fcpxml")
        try xml.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// The real frame rate from the first frames' spacing. The nominal rate
    /// is an average, so source dropouts pull 60 down toward 59.94.
    static func frameRate(of video: AVAssetTrack, in asset: AVURLAsset) async throws -> Double {
        let nominal = Double(try await video.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nominal }
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
            }
        }
        reader.cancelReading()
        return frameRate(fromTimes: times) ?? nominal
    }

    /// Mean frame spacing, skipping gaps over 1.5x the median, snapped to a
    /// standard rate. Mean rather than median because timestamps jitter.
    static func frameRate(fromTimes times: [Double]) -> Double? {
        let sorted = times.sorted()
        guard sorted.count >= 30 else { return nil }
        let spacings = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        let median = spacings.sorted()[spacings.count / 2]
        let steady = spacings.filter { $0 > 0 && $0 < median * 1.5 }
        guard median > 0, !steady.isEmpty else { return nil }
        let rate = Double(steady.count) / steady.reduce(0, +)
        let standard: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 120]
        let nearest = standard.min { abs($0 - rate) < abs($1 - rate) }!
        return abs(nearest - rate) < 0.5 ? nearest : rate
    }

    static func document(movURL: URL, markers: [(title: String, seconds: Double)],
                         width: Int, height: Int, fps: Double, duration: Double,
                         audioTracks: Int, eventName: String = "Recaptr") -> String {
        // Frame duration as a rational, so markers land exactly on frames.
        let (num, den): (Int, Int) =
            abs(fps - 59.94) < 0.05 ? (1001, 60000) :
            abs(fps - 29.97) < 0.05 ? (1001, 30000) :
            (1, max(1, Int(fps.rounded())))
        func time(_ seconds: Double) -> String {
            let frames = Int((seconds * Double(den) / Double(num)).rounded())
            return "\(frames * num)/\(den)s"
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        let name = esc(movURL.deletingPathExtension().lastPathComponent)
        let markerLines = markers.map {
            "      <marker start=\"\(time($0.seconds))\" duration=\"\(num)/\(den)s\" value=\"\(esc($0.title))\"/>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
          <resources>
            <format id="r1" frameDuration="\(num)/\(den)s" width="\(width)" height="\(height)"/>
            <asset id="r2" name="\(name)" start="0s" duration="\(time(duration))" hasVideo="1" format="r1" hasAudio="1" audioSources="\(max(audioTracks, 1))" audioChannels="2" audioRate="48000">
              <media-rep kind="original-media" src="\(esc(movURL.absoluteString))"/>
            </asset>
          </resources>
          <event name="\(esc(eventName))">
            <asset-clip ref="r2" name="\(name)" duration="\(time(duration))" format="r1" tcFormat="NDF">
        \(markerLines)
            </asset-clip>
          </event>
        </fcpxml>

        """
    }
}
