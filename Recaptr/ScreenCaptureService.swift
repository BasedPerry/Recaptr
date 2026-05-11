//
//  ScreenCaptureService.swift
//  Recaptr
//
//  Phase 5.2 (2026-05-11): screen capture via ScreenCaptureKit.
//  Phase 5b (2026-05-11 evening): added SCStream system-audio loopback
//    via SCStreamOutputType.audio. Promoted from spike after Phase 5's
//    first real test (Safari + YouTube) hit the predicted "no good
//    system-audio source in the available list" problem. iPhone-mic
//    via Continuity starved (push=100608 / zf=6945 over 128s = ~2s of
//    real audio). SCStream audio is Tahoe-native, shares the host
//    clock with video, and bypasses the AudioMixer HAL-conflict trap
//    that motivated the Phase 4.8 deferral.
//
//  Mirrors CameraCaptureService's two-output pattern (decision 5):
//  one SCStream delivers frames; we fan out to preview + record from
//  the delegate callback. For screen sources, audio comes from this
//  SAME stream rather than the AudioMixer — MainViewModel bypasses the
//  mixer when the source is .screenDisplay or .screenWindow. Camera
//  sources keep the Phase 4.x mixer path (mic capture).
//
//  Lifecycle:
//    start(filter:previewSink:) — builds SCStreamConfiguration (1080p60
//      BGRA), creates the SCStream, registers self as both delegate and
//      sample-handler, starts capture. Returns the configured CMVideoDimensions
//      so MainViewModel can pass them to the recorder. Throws on any
//      configuration failure.
//    stop() — calls SCStream.stopCapture(); drops the stream reference.
//
//  Permission: ScreenCaptureKit routes through TCC "Screen & System Audio
//  Recording." First call will fail with a no-permission error if the
//  user hasn't authorized the bundle in System Settings → Privacy & Security
//  → Screen Recording. MainViewModel handles the prompt (see Phase 5.4
//  requestScreenCapturePermissionIfNeeded) before start() is called.
//
//  Frame status: SCStream emits a frame for every refresh cycle, including
//  no-change "idle" frames that don't carry pixel data. We filter to
//  SCFrameStatus.complete so the preview layer and the recorder only see
//  buffers with real content.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class ScreenCaptureService: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {

    // Separate queues per output type. SCStream's .screen and .audio
    // outputs deliver on whichever queue we register, and AVAssetWriter
    // append() doesn't block, so a single queue per type is plenty.
    private let videoQueue = DispatchQueue(label: "recaptr.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "recaptr.screen.audio", qos: .userInitiated)

    private var stream: SCStream?
    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    /// Set by MainViewModel before start(). Receives each non-idle frame
    /// so the Recorder can append when isRecording is true. (The Recorder
    /// itself ignores buffers when its writer is not running, matching
    /// the camera-path contract — see Recorder.appendVideo().)
    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// Phase 5b — SCStream system-audio buffers (PCM Float32 stereo at
    /// 48 kHz, per SCStreamConfiguration). Wired to recorder.appendAudio
    /// in MainViewModel for screen sources. AVAssetWriterInput configured
    /// for AAC accepts PCM input in transcode mode, so no extra
    /// conversion is needed.
    var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    /// Surfaces SCStreamDelegate.didStopWithError so MainViewModel can
    /// react to a stream that died mid-capture (display unplugged,
    /// captured window closed, permission revoked).
    var onStreamStopped: ((Error?) -> Void)?

    /// Build and start an SCStream against the given filter. The filter
    /// is constructed by the caller (display vs window vs filtered display
    /// is its decision — we just consume the result).
    func start(filter: SCContentFilter,
               previewSink: SampleBufferPreviewLayer) async throws -> CMVideoDimensions {
        // Tear down any prior stream before reusing this service.
        if stream != nil {
            await stop()
        }
        self.previewSinkLayer = previewSink

        let config = SCStreamConfiguration()
        // Lock 1080p60 to match the camera-path Recorder settings
        // (Phase 5.6). Resolution comes from the configuration, not
        // from the source — SCStream will scale/letterbox as needed.
        config.width  = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // BGRA — the Recorder's H.264 encoder accepts BGRA (it converts
        // to YUV420 internally). Camera path uses 420v; SCStream's
        // preferred format on Apple Silicon is BGRA; both produce H.264.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Small queue, drop late frames. SCStream blocks the system
        // compositor briefly if its queue is full — keep it short.
        config.queueDepth  = 5
        // Cursor is part of the captured frame. Creators almost always
        // want it; UI flag for hiding it can come later if Brandon wants.
        config.showsCursor = true

        // Phase 5b — enable system-audio loopback. SCStream delivers
        // PCM Float32 stereo at the configured rate via the .audio
        // output type. Recorder's AAC writer accepts PCM in transcode
        // mode, so we route SCStream audio buffers straight to
        // recorder.appendAudio (see MainViewModel).
        config.capturesAudio = true
        config.sampleRate    = 48_000
        config.channelCount  = 2
        // Suppress Recaptr's own audio output from the loopback (e.g.
        // if a future monitor plays through system speakers, we don't
        // want to feed it back into the recording).
        config.excludesCurrentProcessAudio = true

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)

        try await s.startCapture()

        self.stream = s
        self.activeDimensions = CMVideoDimensions(width: Int32(config.width),
                                                  height: Int32(config.height))
        print("ScreenCaptureService: started — \(config.width)×\(config.height) @ \(config.minimumFrameInterval.timescale)fps BGRA + audio \(config.sampleRate)Hz×\(config.channelCount)ch")
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
        activeDimensions = .init(width: 0, height: 0)
    }

    // MARK: - SCStreamOutput
    //
    // Delegate methods are NOT marked `nonisolated` — that pattern
    // tripped Swift 6 strict-concurrency warnings (the inferred main-
    // actor isolation of stored properties leaked into the nonisolated
    // function body). CameraCaptureService follows the same convention:
    // delegate methods take their isolation from the class, not from an
    // explicit annotation. Either way, SCStream calls these on the
    // queue we registered (outputQueue) — the keyword only changes
    // Swift's type-level view, not actual execution thread.

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // Filter out idle frames — SCStream emits a frame per refresh
            // cycle even when nothing changed on screen. .complete frames
            // are the only ones carrying real pixel data.
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let attachments = attachmentsArray.first,
               let statusRaw = attachments[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status != .complete {
                return
            }
            // Fan out. previewSinkLayer.enqueue and onRecordBuffer (which
            // dispatches to Recorder.writerQueue) are both thread-safe and
            // non-blocking — no need to hop to another queue here.
            previewSinkLayer?.enqueue(sampleBuffer)
            onRecordBuffer?(sampleBuffer)

        case .audio:
            // Phase 5b — SCStream system audio. CMSampleBuffer carries
            // PCM Float32 at the configured rate, with PTS in the same
            // host-clock domain as video (so recorder.appendAudio's
            // session-anchor logic works without changes).
            onAudioBuffer?(sampleBuffer)

        case .microphone:
            // macOS 15+ adds a separate .microphone output type. Not
            // wired in Phase 5b — mic narration on top of system audio
            // is Phase 6 work (would route through AudioMixer alongside
            // SCStream system audio, with per-source levels).
            break

        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate
    //
    // Observed (2026-05-11 Phase 5 first run): SCStream can succeed
    // startCapture() and then ~100ms later call this method with
    // "Failed to find any displays or windows to capture" (-3801ish
    // family). User-level recovery: hit Start Preview again. Underlying
    // cause appears to be a stale SCContentFilter resolution; not yet
    // worth auto-retrying because the second attempt always succeeds.

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureService: stream stopped with error: \(error.localizedDescription)")
        onStreamStopped?(error)
    }
}
