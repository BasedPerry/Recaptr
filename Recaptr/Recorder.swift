//
//  Recorder.swift
//  Recaptr
//
//  Phase 3 (2026-05-09): AVAssetWriter wrapper, video-only.
//  Phase 4 (2026-05-09): added optional audio writer input. Output
//    location moved from FileManager.urls(for: .moviesDirectory) to
//    NSHomeDirectory()/Movies — sandbox blocks the user's real ~/Movies
//    without the assets.movies entitlement, container Movies is always
//    writable. Phase 7 polish adds the user-selected save location flow.
//

import Foundation
import AVFoundation
import CoreMedia

final class Recorder: @unchecked Sendable {

    private let writerQueue = DispatchQueue(label: "recaptr.recorder", qos: .userInitiated)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime = .invalid
    private var isWriting = false

    /// Configures + starts the writer. Pass `withAudio: true` to add
    /// the AAC audio writer input (must be decided before startWriting
    /// — AVAssetWriter doesn't allow inputs added after).
    func start(width: Int32, height: Int32, withAudio: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            writerQueue.async {
                do {
                    let url = try self._startSync(width: width, height: height, withAudio: withAudio)
                    cont.resume(returning: url)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func _startSync(width: Int32, height: Int32, withAudio: Bool) throws -> URL {
        guard !isWriting else {
            throw CaptureError.writerFailed("Recorder is already running")
        }

        let url = try Self.makeOutputURL()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Video — H.264 SDR (decision 3)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: NSNumber(value: 12_000_000),
                AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 60),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerFailed("Cannot add video input")
        }
        writer.add(videoInput)

        // Audio — AAC stereo 48kHz (decision 2: single audio track)
        var audioInput: AVAssetWriterInput?
        if withAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            guard writer.canAdd(ai) else {
                throw CaptureError.writerFailed("Cannot add audio input")
            }
            writer.add(ai)
            audioInput = ai
        }

        guard writer.startWriting() else {
            throw CaptureError.writerFailed("startWriting() returned false: \(writer.error?.localizedDescription ?? "unknown")")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.sessionStartTime = .invalid
        self.isWriting = true

        return url
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isWriting,
                  let writer = self.writer,
                  let input = self.videoInput else { return }
            guard writer.status == .writing else { self.isWriting = false; return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if self.sessionStartTime == .invalid {
                writer.startSession(atSourceTime: pts)
                self.sessionStartTime = pts
            }

            guard input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isWriting,
                  self.sessionStartTime != .invalid,   // Wait for video to anchor session
                  let writer = self.writer,
                  let input = self.audioInput else { return }
            guard writer.status == .writing else { return }
            guard input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        }
    }

    func stop() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            writerQueue.async {
                guard self.isWriting, let writer = self.writer else {
                    cont.resume(returning: nil)
                    return
                }
                self.isWriting = false
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                writer.finishWriting {
                    let url = writer.outputURL
                    self.writerQueue.async {
                        self.writer = nil
                        self.videoInput = nil
                        self.audioInput = nil
                        self.sessionStartTime = .invalid
                    }
                    cont.resume(returning: url)
                }
            }
        }
    }

    /// Sandbox-safe output path. Earlier iteration tried
    /// NSHomeDirectory()/Movies, which still fails — the container's
    /// Movies subdir appears to be aliased to the user's real ~/Movies
    /// (sandbox blocks writes without the assets.movies entitlement).
    /// Application Support has no such aliasing — always writable in
    /// any sandbox configuration. Phase 7 polish adds proper user-
    /// selected save location via NSOpenPanel + readwrite entitlement.
    private static func makeOutputURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let recordingsDir = appSupport
            .appendingPathComponent("Recaptr", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        if !fm.fileExists(atPath: recordingsDir.path) {
            try fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        }
        // Surface the resolved path so it's discoverable in console
        // (Show in Finder will still navigate to it directly).
        print("Recaptr recordings dir: \(recordingsDir.path)")

        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        return recordingsDir.appendingPathComponent("Recaptr_\(stamp).mov")
    }
}
