//
//  FinalCutMarkers.swift
//  Recaptr
//
//  Writes a Final Cut Pro XML file next to a recording that has clip
//  markers. Final Cut doesn't read the markers stored inside the .mov
//  (a timed-metadata track), so the .fcpxml carries them: double-click
//  it (or File > Import > XML) and the clip arrives with every marker
//  on its frame.
//
//  Markers are read back from the finished file, so the file stays
//  the single source of truth. FCPXML 1.11 (Final Cut 10.6.6 and
//  later); validated against Final Cut's bundled DTD.
//

import Foundation
import AVFoundation

enum FinalCutMarkers {

    /// Write `<recording>.fcpxml` beside `movURL` if the file has
    /// markers. Returns the written URL, or nil when there were none.
    @discardableResult
    static func writeIfNeeded(for movURL: URL) async throws -> URL? {
        let asset = AVURLAsset(url: movURL)
        let markers = try await readMarkers(asset)
        guard !markers.isEmpty,
              let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }

        let size = try await video.load(.naturalSize)
        let fps = Double(try await video.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio).count

        let xml = document(movURL: movURL, markers: markers, width: Int(size.width),
                           height: Int(size.height), fps: fps, duration: duration,
                           audioTracks: audioTracks)
        let out = movURL.deletingPathExtension().appendingPathExtension("fcpxml")
        try xml.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Marker titles and start times from the recording's marker
    /// track, skipping the implicit "Start" range.
    static func readMarkers(_ asset: AVURLAsset) async throws -> [(title: String, seconds: Double)] {
        guard let track = try await asset.loadTracks(withMediaType: .metadata).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let provider = reader.outputMetadataProvider(for: output)
        try reader.start()
        var markers: [(String, Double)] = []
        while let group = try await provider.next() {
            let loaded = try? await group.items.first?.load(.stringValue)
            let title = (loaded ?? nil) ?? "Marker"
            if title != "Start" { markers.append((title, group.timeRange.start.seconds)) }
        }
        return markers
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
