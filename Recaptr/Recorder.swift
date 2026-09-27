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
//      The counters distinguish "rejected by our guards", "input not
//      ready", and "rejected by the writer" (a thrown append error,
//      typically a format mismatch with the configured output).
//    - Uses the macOS 26 receiver API: `AVAssetWriter.inputReceiver`
//      replaces `add(_:)`, `start()` replaces `startWriting()`, and
//      `appendImmediately` replaces the `isReadyForMoreMediaData` +
//      `append` pair. `appendImmediately` returns false when the input
//      isn't ready and throws when the writer rejects a buffer, so
//      neither case can fail silently. `expectsMediaDataInRealTime`
//      stays on deliberately; see `_startSync`.
//

import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Recording presets. Chosen from a measured comparison on 1080p60
/// gameplay (2026-09-26): HEVC gives about 2 dB PSNR more than H.264
/// at the same size, and the macOS 27 constant-quality factor had no
/// effect through AVAssetWriter, so presets are codec + bitrate.
enum VideoQuality: String, CaseIterable, Identifiable {
    /// HEVC 20 Mbps (~8 GB/hour). Matches H.264 at 30 Mbps.
    case standard
    /// HEVC 30 Mbps (~13 GB/hour). Matches H.264 at 40 Mbps.
    case high
    /// H.264 30 Mbps (~13 GB/hour) for tools that can't open HEVC.
    case compatible

    var id: Self { self }

    /// Saved choices from earlier builds map to the nearest preset.
    init(savedValue: String?) {
        switch savedValue {
        case "constantQuality": self = .high
        case let v?: self = VideoQuality(rawValue: v) ?? .standard
        case nil: self = .standard
        }
    }

    var label: String {
        switch self {
        case .standard:   return "Standard (HEVC)"
        case .high:       return "High (HEVC)"
        case .compatible: return "Compatible (H.264)"
        }
    }

    var codec: AVVideoCodecType {
        self == .compatible ? .h264 : .hevc
    }

    /// Bitrate at 1080p60, the resolution the presets were measured at.
    var bitrateAt1080p60: Int {
        switch self {
        case .standard:   return 20_000_000
        case .high:       return 30_000_000
        case .compatible: return 30_000_000
        }
    }

    /// Bitrate for a capture size: same bits per pixel as the 1080p60
    /// measurement, so a 4K recording looks as good per pixel as a
    /// 1080p one (4K Standard = 80 Mbps).
    func bitrate(width: Int32, height: Int32) -> Int {
        let scale = Double(width) * Double(height) / (1920.0 * 1080.0)
        return Int(Double(bitrateAt1080p60) * max(scale, 0.25))
    }

    /// Approximate file size per hour at a capture size.
    func gigabytesPerHour(width: Int32, height: Int32) -> Double {
        Double(bitrate(width: width, height: height)) * 3600 / 8 / 1e9
    }
}

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
    /// Video buffers the writer rejected with a thrown error. Stays
    /// at zero in a healthy recording.
    var videoAppendRejected: Int = 0
    /// Video buffers dropped because their PTS was less than or equal
    /// to the previously accepted video buffer's PTS. `SCStream`
    /// occasionally delivers consecutive samples with equal PTS, which
    /// `AVAssetWriter` accepts but the muxer warns about
    /// (non-monotonic DTS). `AVCaptureSession` is monotonic by
    /// contract, so this counter stays at zero for camera recordings
    /// and climbs modestly during screen captures.
    var videoDroppedPtsRegression: Int = 0
    var writerErrorDescription: String?
    /// Most recent append error thrown by either receiver.
    var lastAppendError: String?
    /// Buffers accepted across the per-source audio tracks.
    var sourceTrackAccepted: Int = 0
}

final class Recorder: @unchecked Sendable {

    private let writerQueue = DispatchQueue(label: "recaptr.recorder", qos: .userInitiated)

    private var writer: AVAssetWriter?
    private var videoReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    /// Clip marker times on the capture clock. Kept in memory and
    /// handed to the Final Cut .fcpxml when the take stops, not
    /// written into the .mov.
    ///
    /// History (tested 2026-09-26): markers used to be a timed-metadata
    /// track written live. Final Cut ignores that track, QuickTime
    /// doesn't list it, and in 4K takes a second marker sample made
    /// the writer fail the next append (-11800 / -17771) about 0.5 s
    /// later, losing the whole file: 4 of 9 takes as contiguous
    /// ranges, 9 of 9 as frame-long samples, with or without the
    /// chapter-list link. Writing the samples at stop instead left a
    /// file AVFoundation couldn't open.
    private var markerTimes: [CMTime] = []
    /// Marker offsets in seconds from the first frame of the last
    /// finished take. Set by `stop()` before it returns.
    private(set) var lastMarkerSeconds: [Double] = []

    /// Per-source audio tracks keyed by mixer channel label ("Audio",
    /// "Mic", "System"). Empty for single-source recordings.
    private var sourceReceivers: [String: AVAssetWriterInput.SampleBufferReceiver] = [:]
    /// First source track; counted as the audio track in stats when
    /// there is no separate mix track.
    private var primarySource: String?
    private var sessionStartTime: CMTime = .invalid
    private var isWriting = false

    // Telemetry — only mutated on writerQueue, snapshotted via stats().
    private var videoAccepted: Int = 0
    private var audioAccepted: Int = 0
    private var audioDroppedPreAnchor: Int = 0
    private var audioDroppedNotReady: Int = 0
    private var videoDroppedNotReady: Int = 0
    private var audioAppendRejected: Int = 0
    private var videoAppendRejected: Int = 0
    private var videoDroppedPtsRegression: Int = 0
    private var lastAppendError: String?
    private var sourceTrackAccepted: Int = 0
    /// Last accepted video PTS, used for the strict-monotonic guard
    /// in `appendVideo`. Reset to `.invalid` in `_startSync`.
    /// Newest video PTS accepted into `pendingVideo` (or written).
    private var lastVideoPTS: CMTime = .invalid
    /// Video frames waiting for the encoder. In real-time mode the
    /// encoder is occasionally "not ready" for a moment; dropping those
    /// frames cost ~2 fps under load (a UI test run measured 57.7 fps,
    /// 2026-09-27). Holding a few and appending them as soon as it's
    /// ready turns a brief stall into a few ms of delay. Capped so a
    /// stuck encoder can't hold camera buffers the capture pool needs.
    /// writerQueue only.
    private var pendingVideo: [CMSampleBuffer] = []
    private static let maxPendingVideo = 4

    /// Configure and start the writer. Pass `withAudio: true` to add
    /// the AAC audio input. The decision must be made before
    /// `start()`; `AVAssetWriter` doesn't allow inputs to be added
    /// afterward.
    ///
    /// `sourceTracks` switches to one audio track per named source
    /// (mixer channel labels) for multi-source recordings, all enabled
    /// and without a separate mix track: editors get each source as its
    /// own component and players sum them.
    ///
    /// `saveDirectory` is the resolved folder (user-selected via
    /// `RecordingStorage`, with the sandbox container as a fallback).
    /// The caller is responsible for holding security scope on that
    /// directory for the lifetime of the write.
    func start(width: Int32, height: Int32, withAudio: Bool, sourceTracks: [String] = [],
               quality: VideoQuality = .standard,
               saveDirectory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            writerQueue.async {
                do {
                    let url = try self._startSync(width: width, height: height, withAudio: withAudio,
                                                  sourceTracks: sourceTracks, quality: quality,
                                                  saveDirectory: saveDirectory)
                    cont.resume(returning: url)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func _startSync(width: Int32, height: Int32, withAudio: Bool, sourceTracks: [String],
                            quality: VideoQuality, saveDirectory: URL) throws -> URL {
        guard !isWriting else {
            throw CaptureError.writerFailed("Recorder is already running")
        }

        let url = try Self.makeOutputURL(in: saveDirectory)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Crash safety: write the movie in fragments, so if the Mac
        // crashes, loses power or Recaptr is force-quit mid-take, the
        // file still opens with everything up to the last fragment.
        // Without this the index is only written at stop, and an
        // interrupted take was unreadable.
        writer.movieFragmentInterval = Self.fragmentInterval
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "RecaptrUITesting"),
           UserDefaults.standard.bool(forKey: "RecaptrUITestNoFragments") {
            writer.movieFragmentInterval = .invalid
        }
        #endif

        // Video — HEVC or H.264 per preset, SDR.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: quality.codec,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoCompressionPropertiesKey: Self.compressionProperties(for: quality, width: width, height: height),
        ]
        // A setting the encoder rejects would raise an uncatchable
        // exception at input creation; check first.
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CaptureError.writerFailed("Encoder rejected the \(quality.label) settings")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        Self.markRealTime(videoInput)
        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerFailed("Cannot add video input")
        }
        let videoReceiver = writer.inputReceiver(for: videoInput)

        // Audio — AAC stereo, 48 kHz, single track.
        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if withAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            Self.markRealTime(ai)
            guard writer.canAdd(ai) else {
                throw CaptureError.writerFailed("Cannot add audio input")
            }
            if sourceTracks.isEmpty {
                audioReceiver = writer.inputReceiver(for: ai)
            } else {
                // Multi-source: one enabled track per source and no
                // separate mix. Final Cut shows each as its own audio
                // component (it ignores disabled tracks, so the earlier
                // mix + disabled-alternates layout showed only the
                // mix), and players sum the enabled tracks into the
                // mix. The mixer's linked limiter keeps that sum under
                // full scale. Tested in Final Cut 2026-09-26.
                for label in sourceTracks {
                    let si = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    Self.markRealTime(si)
                    let name = AVMutableMetadataItem()
                    name.identifier = .quickTimeUserDataTrackName
                    name.value = label as NSString
                    si.metadata = [name]
                    guard writer.canAdd(si) else {
                        throw CaptureError.writerFailed("Cannot add audio track \(label)")
                    }
                    sourceReceivers[label] = writer.inputReceiver(for: si)
                }
            }
        }

        do {
            try writer.start()
        } catch {
            throw CaptureError.writerFailed("start() failed: \(error.localizedDescription)")
        }

        self.writer = writer
        self.videoReceiver = videoReceiver
        self.audioReceiver = audioReceiver
        self.markerTimes = []
        self.sessionStartTime = .invalid
        self.isWriting = true

        // Reset counters for this session.
        self.videoAccepted = 0
        self.audioAccepted = 0
        self.audioDroppedPreAnchor = 0
        self.audioDroppedNotReady = 0
        self.videoDroppedNotReady = 0
        self.audioAppendRejected = 0
        self.videoAppendRejected = 0
        self.videoDroppedPtsRegression = 0
        self.lastAppendError = nil
        self.sourceTrackAccepted = 0
        self.primarySource = sourceTracks.first
        self.lastVideoPTS = .invalid
        self.pendingVideo = []

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

    // MARK: - Markers

    /// Drop a clip marker at the current moment. Stamped from the host
    /// clock, the same time base as the capture PTS, so the marker
    /// lines up with the frame on screen when the key was pressed.
    func addMarker() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.async { [weak self] in
            guard let self, self.isWriting, self.sessionStartTime.isValid,
                  CMTimeCompare(now, self.sessionStartTime) > 0 else { return }
            // Two presses inside one frame land on the same frame; keep one.
            if let last = self.markerTimes.last,
               CMTimeGetSeconds(CMTimeSubtract(now, last)) < 1.0 / 60 { return }
            self.markerTimes.append(now)
        }
    }

    /// How much a crash can cost at most.
    static let fragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

    private static func compressionProperties(for quality: VideoQuality,
                                              width: Int32, height: Int32) -> [String: Any] {
        [
            AVVideoAverageBitRateKey: NSNumber(value: quality.bitrate(width: width, height: height)),
            AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 60),
            AVVideoProfileLevelKey: quality.codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                : AVVideoProfileLevelH264HighAutoLevel,
        ]
    }

    /// Error with its domain, code, and underlying error, for the
    /// recording summary (the localized text alone is too generic).
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    /// Every input runs in real-time mode. Swift marks this deprecated
    /// at macOS 27 in favor of the receiver's appendImmediately, but it
    /// is still required. Tested 2026-09-26 with an Elgato 4K X at
    /// 1080p60: without it the writer holds video back to interleave
    /// with audio and appendImmediately reports "not ready" for ~40% of
    /// frames (33.9 fps file); with it, 60.00 fps and zero drops. The
    /// async append alternative would queue up to ~0.5 s of frames and
    /// risks starving the capture buffer pool on long takes.
    private static func markRealTime(_ input: AVAssetWriterInput) {
        input.expectsMediaDataInRealTime = true
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isWriting,
                  let writer = self.writer,
                  let receiver = self.videoReceiver else { return }
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

            self.lastVideoPTS = pts
            self.pendingVideo.append(sampleBuffer)
            if self.pendingVideo.count > Self.maxPendingVideo {
                self.pendingVideo.removeFirst()
                self.videoDroppedNotReady &+= 1
            }
            self.drainPendingVideo(receiver: receiver, writer: writer)
        }
    }

    /// Append queued video frames, oldest first, until the encoder
    /// says it isn't ready. writerQueue only.
    private func drainPendingVideo(receiver: AVAssetWriterInput.SampleBufferReceiver, writer: AVAssetWriter) {
        while let next = pendingVideo.first {
            do {
                guard try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: next)) else { return }
                videoAccepted &+= 1
            } catch {
                videoAppendRejected &+= 1
                lastAppendError = "video: \(Self.describe(error)) writer=\(writer.status.rawValue) \(writer.error.map { Self.describe($0) } ?? "")"
            }
            pendingVideo.removeFirst()
        }
    }

    /// Append audio to the mix track, or with `source` to that
    /// source's own track. Buffers for sources without a track are
    /// ignored (single-source recordings).
    func appendAudio(_ sampleBuffer: CMSampleBuffer, source: String? = nil) {
        writerQueue.async { [weak self] in
            guard let self,
                  self.isWriting,
                  let writer = self.writer else { return }
            let receiver: AVAssetWriterInput.SampleBufferReceiver
            if let source {
                guard let r = self.sourceReceivers[source] else { return }
                receiver = r
            } else {
                guard let r = self.audioReceiver else { return }
                receiver = r
            }
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

            do {
                if try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: sampleBuffer)) {
                    if source == nil || source == self.primarySource { self.audioAccepted &+= 1 }
                    if source != nil { self.sourceTrackAccepted &+= 1 }
                } else {
                    self.audioDroppedNotReady &+= 1
                }
            } catch {
                // If `audioAccepted` stays at zero while this climbs,
                // the writer is refusing our buffers, usually because
                // their format doesn't match the AAC output settings.
                self.audioAppendRejected &+= 1
                self.lastAppendError = "audio\(source.map { "[\($0)]" } ?? ""): \(Self.describe(error)) writer=\(writer.status.rawValue) \(writer.error.map { Self.describe($0) } ?? "")"
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
                videoAppendRejected: self.videoAppendRejected,
                videoDroppedPtsRegression: self.videoDroppedPtsRegression,
                writerErrorDescription: self.writer?.error?.localizedDescription,
                lastAppendError: self.lastAppendError,
                sourceTrackAccepted: self.sourceTrackAccepted
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
                // Hand over any frames still waiting (brief retries).
                if let receiver = self.videoReceiver {
                    for _ in 0..<20 where !self.pendingVideo.isEmpty {
                        self.drainPendingVideo(receiver: receiver, writer: writer)
                        if !self.pendingVideo.isEmpty { Thread.sleep(forTimeInterval: 0.005) }
                    }
                    self.videoDroppedNotReady &+= self.pendingVideo.count
                    self.pendingVideo = []
                }
                let start = self.sessionStartTime
                self.lastMarkerSeconds = start.isValid
                    ? self.markerTimes.map { CMTimeGetSeconds(CMTimeSubtract($0, start)) }
                    : []
                self.videoReceiver?.finish()
                self.audioReceiver?.finish()
                for r in self.sourceReceivers.values { r.finish() }

                writer.finishWriting {
                    let url = writer.outputURL
                    self.writerQueue.async {
                        self.writer = nil
                        self.videoReceiver = nil
                        self.audioReceiver = nil
                        self.sourceReceivers = [:]
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
    static func makeOutputURL(in directory: URL, prefix: String = "Recaptr") throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Surface the resolved path in the console for debugging;
        // "Show in Finder" still navigates there directly.
        print("Recaptr recordings dir: \(directory.path)")

        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(prefix)_\(stamp).mov")
    }
}
