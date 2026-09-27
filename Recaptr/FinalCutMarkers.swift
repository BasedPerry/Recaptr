//
//  FinalCutMarkers.swift
//  Recaptr
//
//  Writes a Final Cut Pro XML file next to a recording that has clip
//  markers. The .fcpxml is where markers live (the .mov has none; see
//  Recorder): double-click it (or File > Import > XML) and the clip
//  arrives with every marker on its frame.
//
//  Frame size, rate and length are read back from the finished file.
//  FCPXML 1.11 (Final Cut 10.6.6 and later); validated against Final
//  Cut's bundled DTD.
//

import Foundation
import AVFoundation

enum FinalCutMarkers {

    /// Write `<recording>.fcpxml` beside `movURL` if the take had
    /// markers (`markerSeconds`: offsets from the first frame).
    /// Returns the written URL, or nil when there were none.
    @discardableResult
    static func writeIfNeeded(for movURL: URL, markerSeconds: [Double]) async throws -> URL? {
        guard !markerSeconds.isEmpty else { return nil }
        let asset = AVURLAsset(url: movURL)
        let markers = markerSeconds.enumerated().map { (title: "Marker \($0.offset + 1)", seconds: $0.element) }
        guard
              let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }

        let size = try await video.load(.naturalSize)
        let fps = try await frameRate(of: video, in: asset)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio).count

        let xml = document(movURL: movURL, markers: markers, width: Int(size.width),
                           height: Int(size.height), fps: fps, duration: duration,
                           audioTracks: audioTracks)
        let out = movURL.deletingPathExtension().appendingPathExtension("fcpxml")
        try xml.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// The capture's real frame rate, from the typical spacing of the
    /// first frames. The track's nominal rate is an average, so frames
    /// lost to a source dropout pull it down: a 2026-09-27 hour at 60
    /// fps averaged 59.944, which read as 59.94 and gave Final Cut the
    /// wrong frame rate.
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

    /// Frame rate from frame times: the mean spacing, leaving out
    /// dropouts (spacings over 1.5x the median), snapped to a standard
    /// rate when close. The mean, not the median, because capture
    /// timestamps jitter by a millisecond or so. Nil with too few frames.
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
                         audioTracks: Int) -> String {
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
          <event name="Recaptr">
            <asset-clip ref="r2" name="\(name)" duration="\(time(duration))" format="r1" tcFormat="NDF">
        \(markerLines)
            </asset-clip>
          </event>
        </fcpxml>

        """
    }
}
