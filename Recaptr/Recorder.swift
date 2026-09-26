//
//  Recorder.swift
//  Recaptr
//
//  `AVAssetWriter` wrapper that muxes the active video pipeline
//  (camera or SCStream) and, optionally, an audio track into an .mov.
//
//  Key non-obvious behaviors documented inline:
//    - The writing session is anchored on the FIRST arriving sample
//      of any media type, video or audio, so a recording doesn't drop
//      the initial 50–200 ms of audio while waiting for the first
//      video frame.
//    - `appendVideo` enforces a strict-monotonic PTS guard.
//      `AVAssetWriter` accepts equal or earlier PTS but the muxer
//      emits non-monotonic-DTS warnings and the resulting file's
//      frame timing is unreliable. `SCStream` occasionally delivers
//      buffers with equal PTS; `AVCaptureSession` does not.
//    - The recorder publishes a thread-safe `RecorderStats` snapshot
//      so a long session shows live evidence that buffers are landing.
//      The counters distinguish "rejected by our guards" from
//      "rejected by AVAssetWriterInput.append()" — the latter is
//      typically a format mismatch with the configured AAC output.
//

import Foundation
import AVFoundation
import CoreMedia

/// Live recorder telemetry for the UI, published from `MainViewModel`.
struct RecorderStats: Equatable {
    var isWriting: Bool = false
    var writerStatus: AVAssetWriter.Status = .unknown
    var sessionAnchored: Bool = false
    var videoAccepted: Int = 0
    var audioAccepted: Int = 0
    var audioDroppedPreAnchor: Int = 0
    var audioDroppedNotReady: Int = 0
    var videoDroppedNotReady: Int = 0
    /// Buffers that passed our guards but were rejected by
    /// `AVAssetWriterInput.append()` returning false. If this climbs
    /// while `audioAccepted` stays at zero, the writer is rejecting
    /// our buffers — usually a format mismatch with the configured
    /// AAC output.
    var audioAppendRejected: Int = 0
    /// Video buffers dropped because their PTS was less than or equal
    /// to the previously accepted video buffer's PTS. `SCStream`
    /// occasionally delivers consecutive samples with equal PTS, which
    /// `AVAssetWriter` accepts but the muxer warns about
    /// (non-monotonic DTS). `AVCaptureSession` is monotonic by
    /// contract, so this counter stays at zero for camera recordings
    /// and climbs modestly during screen captures.
    var videoDroppedPtsRegression: Int = 0
    var writerErrorDescription: String?
}

final class Recorder: @unchecked Sendable {

    private let writerQueue = DispatchQueue(label: "recaptr.recorder", qos: .userInitiated)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStartTime: CMTime = .invalid
    private var isWriting = false

    // Telemetry — only mutated on writerQueue, snapshotted via stats().
    private var videoAccepted: Int = 0
    private var audioAccepted: Int = 0
    private var audioDroppedPreAnchor: Int = 0
    private var audioDroppedNotReady: Int = 0
    private var videoDroppedNotReady: Int = 0
    private var audioAppendRejected: Int = 0
    private var videoDroppedPtsRegression: Int = 0
    /// Last accepted video PTS, used for the strict-monotonic guard
    /// in `appendVideo`. Reset to `.invalid` in `_startSync`.
    private var lastVideoPTS: CMTime = .invalid

    /// Configure and start the writer. Pass `withAudio: true` to add
    /// the AAC audio input. The decision must be made before
    /// `startWriting`; `AVAssetWriter` doesn't allow inputs to be
    /// added afterward.
    ///
    /// `saveDirectory` is the resolved folder (user-selected via
    /// `RecordingStorage`, with the sandbox container as a fallback).
    /// The caller is responsible for holding security scope on that
    /// directory for the lifetime of the write.
    func start(width: Int32, height: Int32, withAudio: Bool, saveDirectory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            writerQueue.async {
                do {
                    let url = try self._startSync(width: width, height: height, withAudio: withAudio, saveDirectory: saveDirectory)
                    cont.resume(returning: url)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func _startSync(width: Int32, height: Int32, withAudio: Bool, saveDirectory: URL) throws -> URL {
        guard !isWriting else {
            throw CaptureError.writerFailed("Recorder is already running")
        }

        let url = try Self.makeOutputURL(in: saveDirectory)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Video — H.264 SDR.
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

        // Audio — AAC stereo, 48 kHz, single track.
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

        // Reset counters for this session.
        self.videoAccepted = 0
        self.audioAccepted = 0
        self.audioDroppedPreAnchor = 0
        self.audioDroppedNotReady = 0
        self.videoDroppedNotReady = 0
        self.audioAppendRejected = 0
        self.videoDroppedPtsRegression = 0
        self.lastVideoPTS = .invalid

        return url
    }

    /// Anchor the writing session on whichever sample type arrives
    /// first — video OR audio. Must be called on writerQueue while
    /// holding `writer`.
    private func anchorSessionIfNeeded(at pts: CMTime, writer: AVAssetWriter) {
        guard self.sessionStartTime == .invalid else { return }
        writer.startSession(atSourceTime: pts)
        self.sessionStartTime = pts
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isWriting,
                  let writer = self.writer,
                  let input = self.videoInput else { return }
            guard writer.status == .writing else {
                // Writer transitioned to .failed/.cancelled — stop accepting.
                self.isWriting = false
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            self.anchorSessionIfNeeded(at: pts, writer: writer)

            // Strict-monotonic PTS guard. `AVAssetWriter` accepts
            // equal or earlier PTS but the muxer emits
            // non-monotonic-DTS warnings and the resulting file's
            // frame timing becomes unreliable for downstream tools
            // (ffprobe, video editors). Drop the offending buffer
            // with a counter so the failure surfaces instead of
            // hiding inside the .mov.
            if self.lastVideoPTS != .invalid,
               CMTimeCompare(pts, self.lastVideoPTS) <= 0 {
                self.videoDroppedPtsRegression &+= 1
                return
            }

            guard input.isReadyForMoreMediaData else {
                self.videoDroppedNotReady &+= 1
                return
            }
            if input.append(sampleBuffer) {
                self.videoAccepted &+= 1
                self.lastVideoPTS = pts
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isWriting,
                  let writer = self.writer,
                  let input = self.audioInput else { return }
            guard writer.status == .writing else {
                self.isWriting = false
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // The first sample of any kind anchors the session, so we
            // don't lose the audio that arrives before the first video
            // frame.
            self.anchorSessionIfNeeded(at: pts, writer: writer)

            // If the anchor was set by a later video frame and an
            // older audio buffer is in flight behind it,
            // `AVAssetWriter` rejects it. Drop explicitly so the
            // counter shows what's happening.
            if CMTimeCompare(pts, self.sessionStartTime) < 0 {
                self.audioDroppedPreAnchor &+= 1
                return
            }

            guard input.isReadyForMoreMediaData else {
                self.audioDroppedNotReady &+= 1
                return
            }
            if input.append(sampleBuffer) {
                self.audioAccepted &+= 1
            } else {
                // Silent rejection — if `audioAccepted` stays at zero
                // while this climbs, the writer is refusing our
                // buffers, usually because their format doesn't match
                // the AAC output settings.
                self.audioAppendRejected &+= 1
            }
        }
    }

    /// Snapshot of recorder state for UI polling. Safe to call from
    /// any thread — hops onto writerQueue synchronously to read.
    func stats() -> RecorderStats {
        writerQueue.sync {
            RecorderStats(
                isWriting: self.isWriting,
                writerStatus: self.writer?.status ?? .unknown,
                sessionAnchored: self.sessionStartTime != .invalid,
                videoAccepted: self.videoAccepted,
                audioAccepted: self.audioAccepted,
                audioDroppedPreAnchor: self.audioDroppedPreAnchor,
                audioDroppedNotReady: self.audioDroppedNotReady,
                videoDroppedNotReady: self.videoDroppedNotReady,
                audioAppendRejected: self.audioAppendRejected,
                videoDroppedPtsRegression: self.videoDroppedPtsRegression,
                writerErrorDescription: self.writer?.error?.localizedDescription
            )
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

    /// Build the output URL inside the caller-provided save directory.
    /// `RecordingStorage` handles the user-selected-vs-sandbox-fallback
    /// decision and security-scoped access; this method just writes
    /// inside the resolved directory. The folder is created if it
    /// doesn't already exist, in case it was removed between
    /// `resolveSaveDirectory` and the start of the write.
    private static func makeOutputURL(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Surface the resolved path in the console for debugging;
        // "Show in Finder" still navigates there directly.
        print("Recaptr recordings dir: \(directory.path)")

        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("Recaptr_\(stamp).mov")
    }
}
