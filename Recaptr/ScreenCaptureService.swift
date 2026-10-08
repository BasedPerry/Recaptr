//
//  ScreenCaptureService.swift
//  Recaptr
//
//  Screen and window capture with ScreenCaptureKit. System audio comes
//  from the same stream, so video and audio share the host clock.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Capture size cap. The source's aspect is kept and it's only scaled down.
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

    private var cap: (Double, Double) {
        switch self {
        case .auto: return (3840, 2160)
        case .qhd:  return (2560, 1440)
        case .fhd:  return (1920, 1080)
        }
    }

    /// Source size fitted into the cap, rounded to even numbers for 4:2:0.
    func fit(_ source: CGSize) -> CMVideoDimensions {
        guard source.width > 0, source.height > 0 else { return .init(width: 1920, height: 1080) }
        // Landscape caps also bound portrait sources by their long side.
        let (capW, capH) = source.width >= source.height ? cap : (cap.1, cap.0)
        let scale = min(1, capW / source.width, capH / source.height)
        func even(_ v: Double) -> Int32 { max(2, Int32((v * scale / 2).rounded()) * 2) }
        return .init(width: even(source.width), height: even(source.height))
    }

    /// Display size in pixels from its current mode, not points.
    static func pixelSize(of display: SCDisplay) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: display.width * 2, height: display.height * 2)
    }

    /// Window size in pixels, using the backing scale of its screen.
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

    private let videoQueue = DispatchQueue(label: "recaptr.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "recaptr.screen.audio", qos: .userInitiated)

    private var stream: SCStream?
    /// The running stream's settings, reused by `restart`.
    private var configuration: SCStreamConfiguration?
    /// Instant-replay buffer, attached only when `instantReplay` is on.
    private var clipBuffer: SCClipBufferingOutput?

    /// Set before `start()`. Keeps the last 15 s for `exportReplay`.
    var instantReplay = false
    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    /// Receives constant-rate frames for the recorder.
    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// System audio as PCM Float32 stereo, 48 kHz. The AAC writer input
    /// takes it without conversion.
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    /// Called when the stream dies (display unplugged, window closed,
    /// permission revoked).
    var onStreamStopped: ((Error?) -> Void)?

    /// Starts a stream for `filter` and returns the capture size.
    func start(filter: SCContentFilter,
               previewSink: SampleBufferPreviewLayer,
               size: CMVideoDimensions = .init(width: 1920, height: 1080),
               frameRate: Int = 60,
               showsCursor: Bool = true) async throws -> CMVideoDimensions {
        if stream != nil {
            await stop()
        }
        self.previewSinkLayer = previewSink

        let config = SCStreamConfiguration()
        config.width  = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // 4:2:0 Rec. 709 is the encoder's native input. BGRA forces a
        // conversion per frame and leaves the file without color tags.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.itur_709
        // Keep this small. A full queue briefly blocks the compositor.
        config.queueDepth  = 5
        config.showsCursor = showsCursor

        config.capturesAudio = true
        config.sampleRate    = 48_000
        config.channelCount  = 2
        // Keeps the live monitor from feeding back into the recording.
        config.excludesCurrentProcessAudio = true

        let s = try await startStream(filter: filter, configuration: config)
        self.stream = s
        self.configuration = config
        resetFrameGrid(frameRate: frameRate)
        seedFirstFrameIfNeeded(filter: filter, configuration: config)
        self.activeDimensions = CMVideoDimensions(width: Int32(config.width),
                                                  height: Int32(config.height))
        print("ScreenCaptureService: started — \(config.width)×\(config.height) @ \(config.minimumFrameInterval.timescale)fps 420v/709 + audio \(config.sampleRate)Hz×\(config.channelCount)ch")
        return activeDimensions
    }

    private func startStream(filter: SCContentFilter, configuration config: SCStreamConfiguration) async throws -> SCStream {
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)

        try await s.startCapture()

        // The clip buffer can only be added to a running stream. If it
        // fails, capture carries on without replay.
        clipBuffer = nil
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
        return s
    }

    /// Starts a new stream after the old one died, with the same settings.
    /// The frame grid keeps repeating the last frame meanwhile, so the
    /// recording shows a short freeze instead of a gap.
    func restart(filter: SCContentFilter) async throws {
        guard let configuration else { throw CaptureError.configurationFailed("Screen capture never started") }
        if let old = stream {
            stream = nil
            try? await old.stopCapture()
        }
        stream = try await startStream(filter: filter, configuration: configuration)
        print("ScreenCaptureService: restarted — \(configuration.width)×\(configuration.height)")
    }

    #if DEBUG
    /// UI test hook: stops the stream as if SCStream had failed.
    func simulateStreamFailure() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        onStreamStopped?(CaptureError.configurationFailed("Simulated stream failure"))
    }
    #endif

    func stop() async {
        guard let s = stream else { return }
        do {
            try await s.stopCapture()
        } catch {
            // A stream that already failed can throw here. Harmless.
            print("ScreenCaptureService: stopCapture threw (likely already stopped): \(error)")
        }
        stream = nil
        configuration = nil
        stopFrameGrid()
        clipBuffer = nil
        activeDimensions = .init(width: 0, height: 0)
    }

    var isReplayBuffering: Bool { clipBuffer != nil }

    /// Saves the last `duration` seconds (max 15). Buffering continues.
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
    // Not marked `nonisolated`: that triggers Swift 6 concurrency
    // warnings. SCStream calls these on the registered queue either way.

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // .complete frames carry new pixels; .idle frames don't.
            // Preview gets real frames, the recording gets the grid.
            let status = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?
                .first?[.status] as? Int
            var isComplete = status == SCFrameStatus.complete.rawValue
            #if DEBUG
            // UI test hook: `-RecaptrUITestIgnoreFramesFor <s>` ignores
            // early frames to exercise `seedFirstFrameIfNeeded`.
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
            onAudioBuffer?(sampleBuffer)

        case .microphone:
            // Not used. The mic goes through AudioMixer.
            break

        @unknown default:
            break
        }
    }

    // MARK: - Constant frame rate

    // SCStream only sends changed frames, which gives a variable frame
    // rate file. The recording instead gets the newest frame on every
    // tick of a fixed grid. Arriving frames fill ticks up to their own
    // time; a timer fills ticks when nothing arrives, since a still
    // screen sends nothing at all. Video queue only.
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
    /// How far the timer trails the clock, so it doesn't race a real
    /// frame still in flight.
    private let fillLatency = CMTime(value: 50, timescale: 1000)
    /// Most frames emitted at once. Further behind than this, the grid
    /// skips ahead. Must stay well above `fillLatency` (3 frames at
    /// 60 fps) or normal timer jitter triggers skips.
    private let maxBurst = 8

    private func resetFrameGrid(frameRate: Int) {
        videoQueue.async { [weak self] in
            guard let self else { return }
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

    /// A still source may never send a frame, leaving the grid nothing
    /// to repeat. If none arrives shortly after start, seed it with a
    /// screenshot at the same size and format.
    private func seedFirstFrameIfNeeded(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, await self.needsFirstFrame() else { return }
            do {
                // Core Media buffers aren't Sendable; this one is only
                // read on the video queue from here on.
                nonisolated(unsafe) let still = try await SCScreenshotManager.captureSampleBuffer(
                    contentFilter: filter, configuration: configuration)
                guard let pixels = CMSampleBufferGetImageBuffer(still) else { return }
                nonisolated(unsafe) let image = pixels
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

    /// Timer tick. The grid uses the host clock, like SCStream's PTS.
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
            if let frame = makeFrame(image, at: gridNext, duration: gridStep) {
                onRecordBuffer?(frame)
            }
            gridNext = CMTimeAdd(gridNext, gridStep)
        }
    }

    /// Reused while it matches the image. Video queue only.
    private var gridFormat: CMVideoFormatDescription?

    private func makeFrame(_ image: CVImageBuffer, at pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        if gridFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(gridFormat!, imageBuffer: image) {
            var made: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                               formatDescriptionOut: &made) == noErr else { return nil }
            gridFormat = made
        }
        guard let format = gridFormat else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - SCStreamDelegate
    //
    // SCStream sometimes starts, then fails ~100 ms later with "Failed to
    // find any displays or windows". A second start works, so this isn't
    // retried automatically.

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureService: stream stopped with error: \(error.localizedDescription)")
        onStreamStopped?(error)
    }
}
