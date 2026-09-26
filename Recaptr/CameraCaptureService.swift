//
//  CameraCaptureService.swift
//  Recaptr
//
//  Video-only capture for an `AVCaptureDevice` (camera or capture
//  card). Builds an `AVCaptureSession` with two parallel video
//  outputs:
//    - preview output → SampleBufferPreviewLayer (drops late frames)
//    - record output  → callback for the recorder (no drops)
//
//  Audio is owned by `AudioMixer`, not this service.
//
//  Two non-obvious bits of capture-card plumbing are documented in
//  `tryLockFormat`: the device must remain locked for the whole
//  session lifetime (OBS pattern), and on macOS Tahoe, frame-rate
//  setters validate `CMTime` by representation rather than numerical
//  equivalence — pass the range's reported `minFrameDuration` through
//  unchanged.
//

import Foundation
import AVFoundation
import QuartzCore  // CACurrentMediaTime

final class CameraCaptureService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "recaptr.camera.session", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "recaptr.camera.preview", qos: .userInteractive)
    private let recordQueue  = DispatchQueue(label: "recaptr.camera.record",  qos: .userInitiated)

    private let previewOutput = AVCaptureVideoDataOutput()
    private let recordOutput  = AVCaptureVideoDataOutput()

    /// Opt-in low-light noise reduction (macOS 27). Set before
    /// `start`. Applied to the record connection only: Apple allows
    /// the feature on one output at a time, and the recording is what
    /// matters. Off by default because it changes the image.
    var lowLightNoiseReduction = false
    /// Whether the active camera format supports it. Valid after
    /// `start` returns.
    private(set) var lowLightNoiseReductionSupported = false

    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    /// Live FPS counter on the preview path. Tracked on `previewQueue`
    /// only (the delegate dispatches the preview output there
    /// serially), reset every second. Used to identify where a
    /// suspected frame-rate drop originates — the source device, the
    /// capture session, or downstream of the delegate.
    private var fpsCountFrames: Int = 0
    private var fpsLastReport: CFTimeInterval = 0

    /// The configured device, kept here so the configuration lock
    /// taken in `tryLockFormat` can be held for the entire session
    /// lifetime (matching OBS's `OBSAVCapture.m` pattern). The device
    /// only honors configured frame durations while it stays locked;
    /// unlocking causes a silent revert to default behavior (typically
    /// 30 fps for USB capture cards). Released in `stop()`.
    private var lockedDevice: AVCaptureDevice?

    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// Configure and start the session for video only. Audio is
    /// handled by `AudioMixer` on a separate path.
    func start(cameraUniqueID: String,
               previewSink: SampleBufferPreviewLayer) async throws -> CMVideoDimensions {
        self.previewSinkLayer = previewSink
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CMVideoDimensions, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(cameraUniqueID: cameraUniqueID)
                    self.session.startRunning()
                    cont.resume(returning: self.activeDimensions)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            // Release the configuration lock held since `tryLockFormat`.
            // Must happen AFTER `stopRunning()` so the session has a
            // chance to flush in-flight frames.
            if let dev = self.lockedDevice {
                dev.unlockForConfiguration()
                self.lockedDevice = nil
            }
        }
    }

    private func configureSession(cameraUniqueID: String) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach  { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // ── Video device + format lock
        guard let videoDevice = AVCaptureDevice(uniqueID: cameraUniqueID) else {
            throw CaptureError.configurationFailed("Camera not found: \(cameraUniqueID)")
        }

        // On macOS, set `activeFormat` AFTER `addInput`. The session's
        // `sessionPreset` (default `.high`) is applied at addInput
        // time and overrides any `activeFormat` set on the device
        // pre-input, silently capping the framerate. iOS's
        // `.inputPriority` preset, which opts out of this, isn't
        // available on macOS — so the workaround is to set the
        // format last and let Apple's documented behavior preserve it:
        //
        //   "If you change the active format on an AVCaptureDevice
        //    that's providing input to a session, the session will
        //    continue to use the input's active format."
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw CaptureError.configurationFailed("Cannot add video input")
        }
        session.addInput(videoInput)
        // Lock the format AFTER the input is in place. `tryLockFormat`
        // acquires the device's configuration lock and keeps it held
        // for the session's lifetime (released in `stop()`). The
        // device only honors frame-duration settings while locked.
        tryLockFormat(for: videoDevice)
        activeDimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)

        // ── Output A — preview
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        previewOutput.setSampleBufferDelegate(self, queue: previewQueue)
        guard session.canAddOutput(previewOutput) else {
            throw CaptureError.configurationFailed("Cannot add preview output")
        }
        session.addOutput(previewOutput)

        // ── Output B — video record
        recordOutput.alwaysDiscardsLateVideoFrames = false
        recordOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        recordOutput.setSampleBufferDelegate(self, queue: recordQueue)
        guard session.canAddOutput(recordOutput) else {
            throw CaptureError.configurationFailed("Cannot add record output")
        }
        session.addOutput(recordOutput)

        if let conn = recordOutput.connection(with: .video) {
            lowLightNoiseReductionSupported = conn.isLowLightVideoNoiseReductionSupported
            if lowLightNoiseReductionSupported {
                // Explicit control: never let the system decide.
                conn.automaticallyEnablesLowLightVideoNoiseReduction = false
                conn.isLowLightVideoNoiseReductionEnabled = lowLightNoiseReduction
            }
            print("CameraCaptureService: low-light noise reduction supported=\(lowLightNoiseReductionSupported) enabled=\(lowLightNoiseReductionSupported && lowLightNoiseReduction)")
        }
    }

    private func tryLockFormat(for device: AVCaptureDevice) {
        // Enumerate every format the device advertises. Surfacing the
        // full list makes it visible whether higher-resolution formats
        // (e.g. 2160p) are reachable through AVFoundation or whether
        // the device only exposes them through vendor-specific CMIO
        // properties.
        let allFormats = device.formats
        print("CameraCaptureService: \(device.localizedName) — \(allFormats.count) total format(s) available:")
        for (i, fmt) in allFormats.enumerated() {
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let ranges = fmt.videoSupportedFrameRateRanges
                .map { String(format: "%.1f–%.1ffps", $0.minFrameRate, $0.maxFrameRate) }
                .joined(separator: ", ")
            let subType = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let subTypeStr = Self.fourCCString(subType)
            print("  [\(i)] \(d.width)×\(d.height) subType=\(subTypeStr) ranges=\(ranges)")
        }

        // Pick a format supporting the target rate, preferring USB-
        // bandwidth-friendly resolutions in order. Raw NV12 at 4K60
        // needs ~6 Gbps, which exceeds USB 3.0's ~5 Gbps usable
        // bandwidth — devices on USB 3.0 will silently throttle to
        // ~30–40 fps at 4K. 1080p60 NV12 is ~1.5 Gbps and fits
        // comfortably on any USB 3.0 capture card.
        //
        // The range filter is epsilon-aware. Two range styles exist
        // in the wild:
        //   - Discrete single-point ranges where rates are reported
        //     at CMTime-rational precision (e.g. "60 fps" = 60.000240),
        //     so a strict `<= literal` comparison rejects them.
        //   - Continuous wide ranges (e.g. 1.0–60.0 on a Continuity
        //     Camera).
        // ε = 0.5 handles the rational-precision case and also covers
        // NTSC 59.94 if we ever target 60.
        let targetRate: Double = 60.0
        let epsilon: Double    = 0.5
        let supportsTarget: (AVFrameRateRange) -> Bool = { range in
            range.minFrameRate <= targetRate + epsilon &&
            range.maxFrameRate >= targetRate - epsilon
        }

        // Resolution preferences in priority order (USB-bandwidth aware).
        let preferredResolutions: [(Int32, Int32)] = [
            (1920, 1080),  // FHD — always USB 3.0 friendly at 60
            (2560, 1440),  // QHD — fits USB 3.0 at 60 (~2.7 Gbps NV12)
            (3440, 1440),  // UWQHD — fits USB 3.0 at 60 (~3.6 Gbps NV12)
            (3840, 2160),  // 4K — needs USB 3.2 Gen 2 for 60; throttles on USB 3.0
        ]

        // Pick the first preferred resolution whose format supports the target rate.
        var picked: AVCaptureDevice.Format?
        for (w, h) in preferredResolutions {
            if let fmt = allFormats.first(where: {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width == w && d.height == h
                    && $0.videoSupportedFrameRateRanges.contains(where: supportsTarget)
            }) {
                picked = fmt
                break
            }
        }

        // Last-resort fallback: any format supporting target rate.
        if picked == nil {
            picked = allFormats.first { f in
                f.videoSupportedFrameRateRanges.contains(where: supportsTarget)
            }
        }

        guard let fmt = picked else {
            print("CameraCaptureService: no format supports \(Int(targetRate))fps, falling through to device default")
            return
        }
        let pickedDims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        print("CameraCaptureService: chose format \(pickedDims.width)×\(pickedDims.height) supporting \(Int(targetRate))fps")
        let pickedRanges = fmt.videoSupportedFrameRateRanges
            .map { String(format: "%.2f–%.2f", $0.minFrameRate, $0.maxFrameRate) }
            .joined(separator: ", ")
        print("CameraCaptureService: picked format, supported ranges=\(pickedRanges)")

        // Use the range's reported `minFrameDuration` as-is — do not
        // synthesize a fresh `CMTime(value: 1, timescale: 60)`.
        //
        // Capture cards typically report 60 fps as a single-point
        // range (60.0–60.0) with the frame duration encoded as a
        // device-specific CMTime such as `CMTime(value: 1_000_000,
        // timescale: 60_000_240)` — mathematically ~1/60.000240, not
        // exactly 1/60. On macOS Tahoe, `AVCaptureDevice` validates
        // the supplied CMTime by representation against its discrete
        // supported durations: `CMTime(value: 1, timescale: 60)`
        // throws `NSInvalidArgumentException` because it doesn't
        // match any of the device's reported durations exactly, even
        // though the rational value is "the same." Pre-Tahoe
        // AVFoundation silently clamped invalid durations to the
        // nearest supported one (typically 30 fps), which produced
        // hard-to-diagnose "records at 30 fps even though we asked
        // for 60" symptoms.
        //
        // Find a range containing the target rate, pull its
        // `minFrameDuration` (the shortest duration = the fastest
        // rate the range supports), and pass that CMTime to the
        // device unchanged. Works for both single-point ranges
        // (60–60 → minDuration = 1/60) and continuous ranges
        // (1–60 → minDuration = 1/60 also).
        guard let range60 = fmt.videoSupportedFrameRateRanges.first(where: supportsTarget) else {
            print("CameraCaptureService: format claimed \(Int(targetRate))p support but no matching range — bailing")
            return
        }
        print(String(
            format: "CameraCaptureService: chosen rate range %.2ffps, frame duration %d/%d (%.6fs)",
            range60.minFrameRate,
            range60.minFrameDuration.value,
            range60.minFrameDuration.timescale,
            range60.minFrameDuration.seconds
        ))

        // Lock the device and HOLD the lock for the session's
        // lifetime — do not defer the unlock. This matches the
        // pattern in OBS's `OBSAVCapture.m`: `lockForConfiguration`,
        // set `activeFormat` and frame durations, `commitConfiguration`,
        // and don't unlock until the device input is being removed.
        // The device only honors configured frame durations while it
        // remains locked; unlocking causes a silent revert to default
        // behavior. Stored in `lockedDevice` so `stop()` can release
        // it.
        do {
            try device.lockForConfiguration()
            lockedDevice = device
            device.activeFormat = fmt
            // Pass the range's CMTime as-is — the device validates by
            // representation, not numerical equivalence (see comment
            // above).
            device.activeVideoMinFrameDuration = range60.minFrameDuration
            device.activeVideoMaxFrameDuration = range60.minFrameDuration

            // Verify the lock took. If AVCaptureSession overrode the
            // request for any reason, surface it instead of silently
            // running at the wrong rate.
            let appliedMin = device.activeVideoMinFrameDuration
            let appliedMax = device.activeVideoMaxFrameDuration
            let effectiveFps = appliedMin.seconds > 0 ? 1.0 / appliedMin.seconds : 0
            print(String(
                format: "CameraCaptureService: post-lock (HELD) — minFrameDuration=%.6fs maxFrameDuration=%.6fs effective=%.2ffps",
                appliedMin.seconds, appliedMax.seconds, effectiveFps
            ))
        } catch {
            print("CameraCaptureService: lockForConfiguration failed: \(error)")
        }
    }

    /// Convert a FourCC code (e.g. kCVPixelFormatType_422YpCbCr10) to a
    /// 4-char readable string. Helpful for spotting 60p vs 30p formats
    /// — some devices encode the rate intent in the codec subtype.
    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8)  & 0xff),
            UInt8(code         & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(code, radix: 16)
        }
        return String(code, radix: 16)
    }

    // MARK: - Delegates

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === previewOutput {
            previewSinkLayer?.enqueue(sampleBuffer)

            // Live FPS counter on the preview path. Counts frames
            // delivered by `AVCaptureSession` and prints once per
            // second. A console reading of 30 while targeting 60 means
            // the source is delivering 30; a reading of 60 with a
            // 30 fps file means the bottleneck is downstream
            // (encoder / muxer). The delegate queue is serial, so the
            // counters don't need atomics.
            fpsCountFrames += 1
            let now = CACurrentMediaTime()
            if fpsLastReport == 0 {
                fpsLastReport = now
            } else if now - fpsLastReport >= 1.0 {
                let elapsed = now - fpsLastReport
                let observed = Double(fpsCountFrames) / elapsed
                print(String(format: "CameraCaptureService: observed %.2f fps (preview path, %d frames in %.3fs)", observed, fpsCountFrames, elapsed))
                fpsCountFrames = 0
                fpsLastReport = now
            }
        } else if output === recordOutput {
            onRecordBuffer?(relabeledAsRec709(sampleBuffer))
        }
    }

    /// Format description for relabeled frames, reused while frames
    /// keep the same shape. Record queue only.
    private var rec709Description: CMVideoFormatDescription?

    /// Relabel a frame as standard HD (Rec. 709). Capture cards like
    /// the Elgato 4K X tag HDMI video with the SMPTE 240M transfer
    /// curve, which editors read as a different gamma. The pixels are
    /// Rec. 709, so only the label changes.
    ///
    /// The writer takes the file's color tags from each sample
    /// buffer's format description (fixed when the camera made it),
    /// so the frame is rewrapped with a description built from the
    /// relabeled pixel buffer. Asking the writer to convert to 709
    /// instead cost up to 20% of frames at 1080p60 (tested
    /// 2026-09-26). Falls back to the original frame on any failure.
    private func relabeledAsRec709(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return sampleBuffer }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        if rec709Description == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(rec709Description!, imageBuffer: pb) {
            var desc: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &desc
            ) == noErr else { return sampleBuffer }
            rec709Description = desc
        }
        guard let desc = rec709Description else { return sampleBuffer }

        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else {
            return sampleBuffer
        }
        var relabeled: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: desc,
            sampleTiming: &timing, sampleBufferOut: &relabeled
        ) == noErr, let relabeled else { return sampleBuffer }
        return relabeled
    }
}
