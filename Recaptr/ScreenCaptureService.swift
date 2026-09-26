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

final class ScreenCaptureService: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {

    // Separate queues per output type. SCStream's .screen and .audio
    // outputs deliver on whichever queue we register, and AVAssetWriter
    // append() doesn't block, so a single queue per type is plenty.
    private let videoQueue = DispatchQueue(label: "recaptr.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "recaptr.screen.audio", qos: .userInitiated)

    private var stream: SCStream?
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
               previewSink: SampleBufferPreviewLayer) async throws -> CMVideoDimensions {
        // Tear down any prior stream before reusing this service.
        if stream != nil {
            await stop()
        }
        self.previewSinkLayer = previewSink

        let config = SCStreamConfiguration()
        // Lock 1080p60 to match the camera-path recorder settings.
        // Resolution comes from the configuration, not from the
        // source — SCStream scales / letterboxes as needed.
        config.width  = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // BGRA: the recorder's H.264 encoder accepts BGRA (it
        // converts to YUV420 internally), and BGRA is SCStream's
        // preferred pixel format on Apple Silicon.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Small queue, drop late frames. SCStream briefly blocks the
        // system compositor if its queue is full — keep it short.
        config.queueDepth  = 5
        // Cursor is part of the captured frame.
        config.showsCursor = true

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
