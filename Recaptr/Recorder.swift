//
//  Recorder.swift
//  Recaptr
//
//  Writes video and optional audio tracks to a .mov with AVAssetWriter.
//

import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Recording presets: codec plus bitrate. The constant-quality setting
/// has no effect through AVAssetWriter, so it isn't used.
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

    /// Bitrate scaled to keep the same bits per pixel as 1080p60
    /// (4K Standard = 80 Mbps).
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
    /// Audio buffers the writer rejected. Climbing while `audioAccepted`
    /// stays at zero usually means a format mismatch with the AAC output.
    var audioAppendRejected: Int = 0
    /// Video buffers the writer rejected. Zero in a healthy recording.
    var videoAppendRejected: Int = 0
    /// Video buffers dropped for a PTS not after the previous one.
    /// SCStream sometimes repeats a PTS; camera capture never does.
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
    /// Clip marker times on the capture clock. They go to the .fcpxml at
    /// stop, not into the .mov: a metadata track makes the writer fail
    /// (-11800) and Final Cut ignores it anyway.
    private var markerTimes: [CMTime] = []
    /// Marker offsets in seconds from the start of the last take.
    private(set) var lastMarkerSeconds: [Double] = []

    /// Per-source audio tracks keyed by mixer channel label. Empty for
    /// single-source recordings.
    private var sourceReceivers: [String: AVAssetWriterInput.SampleBufferReceiver] = [:]
    /// Counted as the audio track in stats when there's no mix track.
    private var primarySource: String?
    private var sessionStartTime: CMTime = .invalid
    private var isWriting = false

    // Telemetry. Mutated on writerQueue only.
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
    /// Newest video PTS accepted, for the monotonic guard in `appendVideo`.
    private var lastVideoPTS: CMTime = .invalid
    /// Frames waiting out a brief encoder "not ready" stall instead of
    /// being dropped. Capped so a stuck encoder can't hold buffers the
    /// capture pool needs. writerQueue only.
    private var pendingVideo: [CMSampleBuffer] = []
    private static let maxPendingVideo = 4

    /// Configures and starts the writer. Inputs can't be added after
    /// start, so audio must be decided here. `sourceTracks` writes one
    /// audio track per source instead of a single mix. The caller holds
    /// security scope on `saveDirectory` for the whole write.
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
        // Fragments keep an interrupted take readable up to the last
        // fragment. Without them the index is only written at stop.
        writer.movieFragmentInterval = Self.fragmentInterval
        #if DEBUG
        // UI test hook: record without fragments.
        if UserDefaults.standard.bool(forKey: "RecaptrUITesting"),
           UserDefaults.standard.bool(forKey: "RecaptrUITestNoFragments") {
            writer.movieFragmentInterval = .invalid
        }
        #endif

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: quality.codec,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoCompressionPropertiesKey: Self.compressionProperties(for: quality, width: width, height: height),
        ]
        // Rejected settings raise an uncatchable exception at input
        // creation, so check first.
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CaptureError.writerFailed("Encoder rejected the \(quality.label) settings")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        Self.markRealTime(videoInput)
        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerFailed("Cannot add video input")
        }
        let videoReceiver = writer.inputReceiver(for: videoInput)

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
                // One enabled track per source, no mix track. Final Cut
                // ignores disabled tracks; players sum the enabled ones.
                // The mixer's limiter keeps that sum under full scale.
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

    /// Starts the session at the first sample of either type, so audio
    /// before the first video frame isn't lost. writerQueue only.
    private func anchorSessionIfNeeded(at pts: CMTime, writer: AVAssetWriter) {
        guard self.sessionStartTime == .invalid else { return }
        writer.startSession(atSourceTime: pts)
        self.sessionStartTime = pts
    }

    // MARK: - Markers

    /// Adds a clip marker now. Uses the host clock, the same time base
    /// as capture PTS.
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

    /// The most a crash can lose.
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

    /// Domain, code and underlying error. The localized text is too
    /// generic for the recording summary.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    /// Deprecated in macOS 27 but still required. Without it the writer
    /// holds video back to interleave with audio and drops ~40% of
    /// frames as "not ready". Async append would queue up to ~0.5 s and
    /// can starve the capture buffer pool.
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
                // Failed or cancelled.
                self.isWriting = false
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            self.anchorSessionIfNeeded(at: pts, writer: writer)

            // The writer accepts a repeated or earlier PTS, but the file
            // ends up with unreliable frame timing. Drop and count it.
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

    /// Appends queued frames until the encoder isn't ready. writerQueue only.
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

    /// Appends to the mix track, or to `source`'s own track. Sources
    /// without a track are ignored.
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
            self.anchorSessionIfNeeded(at: pts, writer: writer)

            // Audio older than a video-set anchor would be rejected.
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
                self.audioAppendRejected &+= 1
                self.lastAppendError = "audio\(source.map { "[\($0)]" } ?? ""): \(Self.describe(error)) writer=\(writer.status.rawValue) \(writer.error.map { Self.describe($0) } ?? "")"
            }
        }
    }

    /// Recorder state for UI polling. Safe from any thread.
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
                // Flush queued frames, with brief retries.
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

    /// Timestamped .mov URL in `directory`. Recreates the folder if it
    /// was removed after `resolveSaveDirectory`.
    static func makeOutputURL(in directory: URL, prefix: String = "Recaptr") throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        print("Recaptr recordings dir: \(directory.path)")

        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(prefix)_\(stamp).mov")
    }
}
