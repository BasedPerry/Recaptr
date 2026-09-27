//
//  ScreenCaptureService.swift
//  Recaptr
//
//  Screen / window capture via ScreenCaptureKit. Mirrors the
//  two-output pattern used in `CameraCaptureService`: one `SCStream`
//  delivers frames and we fan out to preview + record from the
//  delegate callback.
//
//  For screen sources, audio comes from the SAME stream
//  (`SCStreamOutputType.audio`) rather than the `AudioMixer`.
//  `MainViewModel` bypasses the mixer when the source is
//  `.screenDisplay` or `.screenWindow`; camera sources keep the mixer
//  path for mic capture. Using SCStream's audio output keeps video
//  and audio on the same host clock, which makes the recorder's
//  session-anchor logic work without modification, and avoids the
//  AVAudioEngine HAL-conflict that arises when an AVAudioEngine
//  input is open against a system-audio loopback device.
//
//  Lifecycle:
//    - `start(filter:previewSink:)` — builds an `SCStreamConfiguration`
//      (1080p60 BGRA + 48 kHz stereo audio), creates the stream,
//      registers self as both delegate and sample handler, and starts
//      capture. Returns the configured `CMVideoDimensions`. Throws on
//      any configuration failure.
//    - `stop()` — calls `SCStream.stopCapture()` and drops the
//      reference.
//
//  Permission: ScreenCaptureKit routes through TCC "Screen & System
//  Audio Recording." `MainViewModel` handles the prompt
//  (`requestScreenCapturePermissionIfNeeded`) before `start()` is
//  called.
//
//  Frame status: `SCStream` emits a frame for every refresh cycle,
//  including no-change "idle" frames with no real pixel data. The
//  service filters to `SCFrameStatus.complete` so only buffers with
//  fresh content reach the preview layer and the recorder.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Screen and window capture size cap. The capture keeps the
/// source's aspect ratio and pixel size, scaled down to fit the cap
/// (never up).
enum ScreenResolution: String, CaseIterable, Identifiable {
    case auto, qhd, fhd

    var id: Self { self }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .qhd:  return "1440p"
        case .fhd:  return "1080p"
        }
    }

    /// Bounding box the capture must fit in.
    private var cap: (Double, Double) {
        switch self {
        case .auto: return (3840, 2160)
        case .qhd:  return (2560, 1440)
        case .fhd:  return (1920, 1080)
        }
    }

    /// Source size fitted into the cap, aspect kept, even numbers
    /// (4:2:0 video needs them).
    func fit(_ source: CGSize) -> CMVideoDimensions {
        guard source.width > 0, source.height > 0 else { return .init(width: 1920, height: 1080) }
        // Landscape caps also bound portrait sources by their long side.
        let (capW, capH) = source.width >= source.height ? cap : (cap.1, cap.0)
        let scale = min(1, capW / source.width, capH / source.height)
        func even(_ v: Double) -> Int32 { max(2, Int32((v * scale / 2).rounded()) * 2) }
        return .init(width: even(source.width), height: even(source.height))
    }

    /// A display's size in pixels (its current mode, so Retina and
    /// scaled modes report real pixels, not points).
    static func pixelSize(of display: SCDisplay) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: display.width * 2, height: display.height * 2)
    }

    /// A window's size in pixels: its frame in points times the
    /// backing scale of the screen it's on.
    @MainActor
    static func pixelSize(of window: SCWindow) -> CGSize {
        let frame = window.frame
        let screens = NSScreen.screens
        let scale = screens.first { $0.frame.intersects(frame) }?.backingScaleFactor
            ?? screens.first?.backingScaleFactor ?? 2
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }
}

final class ScreenCaptureService: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {

    // Separate queues per output type. SCStream's .screen and .audio
    // outputs deliver on whichever queue we register, and AVAssetWriter
    // append() doesn't block, so a single queue per type is plenty.
    private let videoQueue = DispatchQueue(label: "recaptr.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "recaptr.screen.audio", qos: .userInitiated)

    private var stream: SCStream?
    /// Rolling instant-replay buffer (macOS 27). Only attached when
    /// `instantReplay` is on.
    private var clipBuffer: SCClipBufferingOutput?

    /// Set before `start()`. Keeps the last 15 s of the stream in a
    /// rolling buffer so `exportReplay` can save it on demand.
    var instantReplay = false
    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    /// Set by `MainViewModel` before `start()`. Receives each non-idle
    /// frame so the recorder can append while `isRecording` is true.
    /// (The recorder ignores buffers when its writer is not running,
    /// matching the camera-path contract — see `Recorder.appendVideo()`.)
    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// `SCStream` system-audio buffers (PCM Float32 stereo at 48 kHz,
    /// per `SCStreamConfiguration`). Wired to `recorder.appendAudio`
    /// in `MainViewModel` for screen sources. `AVAssetWriterInput`
    /// configured for AAC accepts PCM input in transcode mode, so no
    /// extra conversion is needed.
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    /// Surfaces `SCStreamDelegate.didStopWithError` so `MainViewModel`
    /// can react to a stream that dies mid-capture (display unplugged,
    /// captured window closed, permission revoked).
    var onStreamStopped: ((Error?) -> Void)?

    /// Build and start an SCStream against the given filter. The filter
    /// is constructed by the caller (display vs window vs filtered display
    /// is its decision — we just consume the result).
    func start(filter: SCContentFilter,
               previewSink: SampleBufferPreviewLayer,
               size: CMVideoDimensions = .init(width: 1920, height: 1080),
               frameRate: Int = 60,
               showsCursor: Bool = true) async throws -> CMVideoDimensions {
        // Tear down any prior stream before reusing this service.
        if stream != nil {
            await stop()
        }
        self.previewSinkLayer = previewSink

        let config = SCStreamConfiguration()
        // Size is chosen by the caller from the source's own pixel
        // size and aspect (capped by the Resolution setting); SCStream
        // scales the content into it.
        config.width  = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // Video-range 4:2:0 in Rec. 709, the encoder's native input.
        // BGRA made the encoder convert every frame and left the file
        // with no color tags (tested 2026-09-27: transfer=unset).
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.itur_709
        // Small queue, drop late frames. SCStream briefly blocks the
        // system compositor if its queue is full — keep it short.
        config.queueDepth  = 5
        config.showsCursor = showsCursor

        // System-audio loopback. SCStream delivers PCM Float32 stereo
        // at the configured rate via the `.audio` output type; the
        // recorder's AAC writer accepts PCM in transcode mode, so
        // these buffers feed `recorder.appendAudio` directly.
        config.capturesAudio = true
        config.sampleRate    = 48_000
        config.channelCount  = 2
        // Suppress Recaptr's own audio output from the loopback (e.g.
        // when the live monitor plays through system speakers, we
        // don't want to feed it back into the recording).
        config.excludesCurrentProcessAudio = true

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)

        try await s.startCapture()

        // The clip buffer can only be added to a running stream. If it
        // fails, capture carries on without replay.
        if instantReplay {
            let clip = SCClipBufferingOutput(delegate: nil)
            do {
                try s.addClipBufferingOutput(clip)
                clipBuffer = clip
                print("ScreenCaptureService: instant replay buffering")
            } catch {
                print("ScreenCaptureService: instant replay unavailable: \(error.localizedDescription)")
            }
        }

        self.stream = s
        resetFrameGrid(frameRate: frameRate)
        seedFirstFrameIfNeeded(filter: filter, configuration: config)
        self.activeDimensions = CMVideoDimensions(width: Int32(config.width),
                                                  height: Int32(config.height))
        print("ScreenCaptureService: started — \(config.width)×\(config.height) @ \(config.minimumFrameInterval.timescale)fps 420v/709 + audio \(config.sampleRate)Hz×\(config.channelCount)ch")
        return activeDimensions
    }

    func stop() async {
        guard let s = stream else { return }
        do {
            try await s.stopCapture()
        } catch {
            // Stopping a stream that already errored out can throw —
            // not a problem on teardown. Log and move on.
            print("ScreenCaptureService: stopCapture threw (likely already stopped): \(error)")
        }
        stream = nil
        stopFrameGrid()
        clipBuffer = nil  // stopping the stream stops buffering
        activeDimensions = .init(width: 0, height: 0)
    }

    /// True while a replay buffer is running.
    var isReplayBuffering: Bool { clipBuffer != nil }

    /// Save the most recent `duration` seconds (max 15) of the stream
    /// to `url`. Buffering continues during the export.
    func exportReplay(to url: URL, duration: TimeInterval = 15) async throws {
        guard let clipBuffer else {
            throw CaptureError.configurationFailed("Instant replay is not running")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            clipBuffer.exportClip(to: url, duration: duration) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    // MARK: - SCStreamOutput
    //
    // Delegate methods intentionally take their isolation from the
    // class rather than carrying explicit `nonisolated` annotations;
    // marking them `nonisolated` trips Swift 6 strict-concurrency
    // warnings when stored properties' inferred actor isolation leaks
    // into the function body. `SCStream` calls these on the queue we
    // registered, regardless of annotation.

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // SCStream sends .complete frames when the screen changes
            // and .idle frames (no pixels) when it doesn't. Preview
            // takes the real frames; the recording gets a steady grid
            // (see `emitGrid`).
            let status = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?
                .first?[.status] as? Int
            var isComplete = status == SCFrameStatus.complete.rawValue
            #if DEBUG
            // UI tests: `-RecaptrUITestIgnoreFramesFor <s>` ignores real
            // frames at the start, as if the source never changed, to
            // exercise `seedFirstFrameIfNeeded`.
            if isComplete, let until = ignoreFramesUntil, Date() < until { isComplete = false }
            #endif
            if isComplete {
                previewSinkLayer?.enqueue(sampleBuffer)
                if let image = CMSampleBufferGetImageBuffer(sampleBuffer) { lastImage = image }
            }
            #if DEBUG
            if !gridNext.isValid, isComplete {
                let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                print(String(format: "ScreenCaptureService: first frame PTS is %.1f ms behind the host clock",
                             (now - CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) * 1000))
            }
            #endif
            if status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.idle.rawValue {
                emitGrid(upTo: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }

        case .audio:
            // System-audio loopback. The `CMSampleBuffer` carries PCM
            // Float32 at the configured rate, with PTS in the same
            // host-clock domain as video (so the recorder's
            // session-anchor logic works without changes).
            onAudioBuffer?(sampleBuffer)

        case .microphone:
            // macOS 15+ adds a separate `.microphone` output type for
            // narration-on-top-of-system-audio capture. Not wired —
            // would route through the AudioMixer alongside SCStream
            // system audio with per-source levels.
            break

        @unknown default:
            break
        }
    }

    // MARK: - Constant frame rate

    // A screen recording made only of changed frames is variable
    // frame rate: a still screen wrote nothing, and a 20 s take
    // averaged 17 fps (2026-09-27). Final Cut conforms such files and
    // the .fcpxml can't infer the rate. Instead the recording gets a
    // frame on every tick of a fixed grid (60 or 30 fps) anchored at
    // the first frame, each showing the newest real frame. Repeated
    // frames cost the HEVC encoder almost nothing.
    //
    // Two things fill the grid: each arriving frame (real or idle)
    // fills ticks up to its own time, and a timer fills ticks when
    // nothing arrives. The timer matters: on a fully still screen
    // SCStream sends nothing at all, and relying on arrivals left a
    // 38 s freeze where a movie was paused (30-minute test,
    // 2026-09-27); after a gap, arrivals also dumped a burst of frames
    // that the real-time encoder partly dropped. Video queue only.
    private var lastImage: CVImageBuffer?
    #if DEBUG
    private let ignoreFramesUntil: Date? = {
        let d = UserDefaults.standard
        let seconds = d.double(forKey: "RecaptrUITestIgnoreFramesFor")
        return d.bool(forKey: "RecaptrUITesting") && seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    }()
    #endif
    private var gridNext: CMTime = .invalid
    private var gridStep = CMTime(value: 1, timescale: 60)
    private var gridTimer: DispatchSourceTimer?
    /// How far the timer lets the grid run behind the clock before it
    /// fills in, so it doesn't race a real frame still in flight.
    private let fillLatency = CMTime(value: 50, timescale: 1000)
    /// Most frames emitted in one go. More than this behind (the Mac
    /// stalled) and the grid jumps ahead instead of flooding the writer.
    private let maxBurst = 3

    private func resetFrameGrid(frameRate: Int) {
        videoQueue.async {
            self.lastImage = nil
            self.gridNext = .invalid
            self.gridStep = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            self.gridTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.videoQueue)
            let interval = 1.0 / Double(frameRate)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.fillFromClock() }
            timer.resume()
            self.gridTimer = timer
        }
    }

    /// SCStream sends pixels only when the content changes, so a still
    /// window (or screen) can go without a single real frame: the grid
    /// then has nothing to repeat and the recording had no video track
    /// at all (a still Finder window, 2026-09-27). If nothing has
    /// arrived shortly after starting, take one still of the source at
    /// the same size and format and start from that.
    private func seedFirstFrameIfNeeded(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, await self.needsFirstFrame() else { return }
            do {
                let still = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter,
                                                                            configuration: configuration)
                guard let image = CMSampleBufferGetImageBuffer(still) else { return }
                self.videoQueue.async {
                    guard self.lastImage == nil else { return }
                    self.lastImage = image
                    self.previewSinkLayer?.enqueue(still)
                    let now = CMClockGetTime(CMClockGetHostTimeClock())
                    self.emitGrid(upTo: CMTimeSubtract(now, self.fillLatency))
                    print("ScreenCaptureService: no frame yet, started from a still")
                }
            } catch {
                print("ScreenCaptureService: couldn't take a first still: \(error.localizedDescription)")
            }
        }
    }

    private func needsFirstFrame() async -> Bool {
        await withCheckedContinuation { cont in
            videoQueue.async { cont.resume(returning: self.lastImage == nil && self.stream != nil) }
        }
    }

    private func stopFrameGrid() {
        videoQueue.async {
            self.gridTimer?.cancel()
            self.gridTimer = nil
            self.lastImage = nil
            self.gridNext = .invalid
        }
    }

    /// Timer tick: fill grid ticks older than `fillLatency`. SCStream
    /// stamps frames on the host clock, so the grid is too.
    private func fillFromClock() {
        guard gridNext.isValid else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        emitGrid(upTo: CMTimeSubtract(now, fillLatency))
    }

    private func emitGrid(upTo time: CMTime) {
        guard let image = lastImage, time.isValid else { return }
        if !gridNext.isValid { gridNext = time }
        // Too far behind: skip ahead, keeping the grid phase.
        let behind = CMTimeSubtract(time, gridNext)
        let steps = Int(behind.seconds / gridStep.seconds)
        if steps > maxBurst {
            gridNext = CMTimeAdd(gridNext, CMTimeMultiply(gridStep, multiplier: Int32(steps - maxBurst + 1)))
        }
        while CMTimeCompare(gridNext, time) <= 0 {
            if let frame = Self.makeFrame(image, at: gridNext, duration: gridStep) {
                onRecordBuffer?(frame)
            }
            gridNext = CMTimeAdd(gridNext, gridStep)
        }
    }

    private static func makeFrame(_ image: CVImageBuffer, at pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - SCStreamDelegate
    //
    // `SCStream` can occasionally accept `startCapture()` and then,
    // ~100 ms later, fire this method with "Failed to find any
    // displays or windows to capture." The cause is a stale
    // `SCContentFilter` resolution; the second attempt always
    // succeeds, so we don't auto-retry — `onStreamStopped` lets
    // `MainViewModel` surface the failure and the user can hit Start
    // Preview again.

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureService: stream stopped with error: \(error.localizedDescription)")
        onStreamStopped?(error)
    }
}
