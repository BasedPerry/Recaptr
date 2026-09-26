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
    /// Marker track for clip markers: a timed-metadata track, linked
    /// to the video as its chapter list. Each marker closes the running
    /// range and opens the next ("Start", "Marker 1", ...), written as
    /// markers drop so a crash mid-take keeps the ones already written.
    ///
    /// Status (tested 2026-09-26): the track, its timing, and the
    /// chapter-list link are all written correctly, but AVFoundation
    /// (and so QuickTime Player) doesn't list metadata-track chapters,
    /// so markers don't yet appear in players' chapter menus. A
    /// QuickTime text-track version made files AVFoundation refused to
    /// open, so it was dropped.
    private var chapterReceiver: AVAssetWriterInput.MetadataReceiver?
    private var chapterStart: CMTime = .invalid
    private var chapterTitle = "Start"
    private var markerCount = 0

    /// Per-source audio tracks keyed by mixer channel label ("Audio",
    /// "Mic", "System"). Empty for single-source recordings.
    private var sourceReceivers: [String: AVAssetWriterInput.SampleBufferReceiver] = [:]
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
    private var lastVideoPTS: CMTime = .invalid

    /// Configure and start the writer. Pass `withAudio: true` to add
    /// the AAC audio input. The decision must be made before
    /// `start()`; `AVAssetWriter` doesn't allow inputs to be added
    /// afterward.
    ///
    /// `sourceTracks` adds one extra audio track per named source
    /// (mixer channel labels) for multi-source recordings. The mix
    /// stays track 1 and the only enabled track; the source tracks are
    /// grouped as its alternates, so players play the mix alone while
    /// editors can still reach each source.
    ///
    /// `saveDirectory` is the resolved folder (user-selected via
    /// `RecordingStorage`, with the sandbox container as a fallback).
    /// The caller is responsible for holding security scope on that
    /// directory for the lifetime of the write.
    func start(width: Int32, height: Int32, withAudio: Bool, sourceTracks: [String] = [],
               saveDirectory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            writerQueue.async {
                do {
                    let url = try self._startSync(width: width, height: height, withAudio: withAudio,
                                                  sourceTracks: sourceTracks, saveDirectory: saveDirectory)
                    cont.resume(returning: url)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func _startSync(width: Int32, height: Int32, withAudio: Bool, sourceTracks: [String],
                            saveDirectory: URL) throws -> URL {
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
            audioReceiver = writer.inputReceiver(for: ai)

            var sourceInputs: [AVAssetWriterInput] = []
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
                sourceInputs.append(si)
            }
            if !sourceInputs.isEmpty {
                // Mix is the default (enabled) track; sources are its
                // alternates, disabled so they don't double the audio.
                let mixName = AVMutableMetadataItem()
                mixName.identifier = .quickTimeUserDataTrackName
                mixName.value = "Mix" as NSString
                ai.metadata = [mixName]
                let group = AVAssetWriterInputGroup(inputs: [ai] + sourceInputs, defaultInput: ai)
                guard writer.canAdd(group) else {
                    throw CaptureError.writerFailed("Cannot group audio tracks")
                }
                writer.add(group)
            }
        }

        // Chapter (marker) track, linked to the video as its chapter
        // list so players show it in their chapter menu.
        let chapterInput = try Self.makeChapterInput()
        guard writer.canAdd(chapterInput) else {
            throw CaptureError.writerFailed("Cannot add chapter track")
        }
        let chapterReceiver = writer.inputMetadataReceiver(for: chapterInput)
        let chapterList = AVAssetTrack.AssociationType.chapterList.rawValue
        if videoInput.canAddTrackAssociation(withTrackOf: chapterInput, type: chapterList) {
            videoInput.addTrackAssociation(withTrackOf: chapterInput, type: chapterList)
        }

        do {
            try writer.start()
        } catch {
            throw CaptureError.writerFailed("start() failed: \(error.localizedDescription)")
        }

        self.writer = writer
        self.videoReceiver = videoReceiver
        self.audioReceiver = audioReceiver
        self.chapterReceiver = chapterReceiver
        self.chapterStart = .invalid
        self.chapterTitle = "Start"
        self.markerCount = 0
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
        self.chapterStart = pts
    }

    // MARK: - Markers (chapters)

    /// Drop a clip marker at the current moment. Stamped from the host
    /// clock, the same time base as the capture PTS, so the chapter
    /// lines up with the frame on screen when the key was pressed.
    func addMarker() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writerQueue.async { [weak self] in
            guard let self, self.isWriting, self.chapterStart.isValid,
                  CMTimeCompare(now, self.chapterStart) > 0 else { return }
            self.writeChapter(until: now)
            self.markerCount += 1
            self.chapterTitle = "Marker \(self.markerCount)"
            self.chapterStart = now
        }
    }

    /// Write the running chapter, ending at `end`. writerQueue only.
    private func writeChapter(until end: CMTime) {
        guard let receiver = chapterReceiver, chapterStart.isValid,
              CMTimeCompare(end, chapterStart) > 0 else { return }
        let group = AVTimedMetadataGroup(
            items: [Self.chapterItem(title: chapterTitle)],
            timeRange: CMTimeRange(start: chapterStart, end: end)
        )
        do {
            _ = try receiver.appendImmediately(group)
        } catch {
            lastAppendError = "chapter: \(error.localizedDescription)"
        }
    }

    /// One chapter title item. Every chapter uses this exact shape
    /// (identifier, UTF-8, language "en"), and the track's format is
    /// derived from it: AVFoundation raises an uncatchable exception
    /// if an appended group doesn't match the track format.
    private static func chapterItem(title: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.extendedLanguageTag = "en"
        item.value = title as NSString
        return item
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

    private static func makeChapterInput() throws -> AVAssetWriterInput {
        let template = AVTimedMetadataGroup(
            items: [chapterItem(title: "Start")],
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        )
        guard let desc = template.copyFormatDescription() else {
            throw CaptureError.writerFailed("Chapter format description unavailable")
        }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
        // Chapter readers look chapters up by locale, and QuickTime
        // convention keeps a chapter track disabled.
        input.languageCode = "eng"
        input.extendedLanguageTag = "en"
        input.marksOutputTrackAsEnabled = false
        // Sparse track: without real-time mode the writer would hold
        // video back waiting to interleave marker samples.
        markRealTime(input)
        return input
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

            do {
                if try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: sampleBuffer)) {
                    self.videoAccepted &+= 1
                    self.lastVideoPTS = pts
                } else {
                    self.videoDroppedNotReady &+= 1
                }
            } catch {
                self.videoAppendRejected &+= 1
                self.lastAppendError = "video: \(error.localizedDescription)"
            }
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
                    if source == nil { self.audioAccepted &+= 1 } else { self.sourceTrackAccepted &+= 1 }
                } else {
                    self.audioDroppedNotReady &+= 1
                }
            } catch {
                // If `audioAccepted` stays at zero while this climbs,
                // the writer is refusing our buffers, usually because
                // their format doesn't match the AAC output settings.
                self.audioAppendRejected &+= 1
                self.lastAppendError = "audio: \(error.localizedDescription)"
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
                // Close the last chapter at the last written frame. A
                // take without markers writes no chapters at all.
                if self.markerCount > 0, self.lastVideoPTS.isValid {
                    self.writeChapter(until: self.lastVideoPTS)
                }
                self.chapterReceiver?.finish()
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
                        self.chapterReceiver = nil
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
