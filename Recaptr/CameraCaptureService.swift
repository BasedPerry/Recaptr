//
//  CameraCaptureService.swift
//  Recaptr
//
//  Video capture from a camera or capture card. One output feeds the
//  preview (drops late frames), the other the recorder (no drops).
//  Audio is handled by AudioMixer.
//

import Foundation
import AVFoundation
import QuartzCore

/// Capture resolution preference for camera and capture-card sources.
enum CaptureResolution: String, CaseIterable, Identifiable {
    case auto, uhd, qhd, fhd

    var id: Self { self }

    var label: String {
        switch self {
        case .auto: return "Auto (highest at 60 fps)"
        case .uhd:  return "4K (3840×2160)"
        case .qhd:  return "1440p (2560×1440)"
        case .fhd:  return "1080p (1920×1080)"
        }
    }

    /// Resolutions to try, best first. A specific choice falls back to
    /// the next smaller one if the device doesn't offer it at 60 fps.
    var searchOrder: [(Int32, Int32)] {
        let all: [(Int32, Int32)] = [(3840, 2160), (3440, 1440), (2560, 1440), (1920, 1080)]
        switch self {
        case .auto: return all
        case .uhd:  return all
        case .qhd:  return [(2560, 1440), (1920, 1080)]
        case .fhd:  return [(1920, 1080)]
        }
    }
}

final class CameraCaptureService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "recaptr.camera.session", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "recaptr.camera.preview", qos: .userInteractive)
    private let recordQueue  = DispatchQueue(label: "recaptr.camera.record",  qos: .userInitiated)

    private let previewOutput = AVCaptureVideoDataOutput()
    private let recordOutput  = AVCaptureVideoDataOutput()

    /// Set before `start`. `.auto` takes the highest resolution at 60 fps.
    var preferredResolution: CaptureResolution = .auto

    /// Set before `start`. Applies to the record output only, since it's
    /// allowed on one output at a time. Off by default: it changes the image.
    var lowLightNoiseReduction = false
    /// Valid after `start` returns.
    private(set) var lowLightNoiseReductionSupported = false

    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    /// Preview-path FPS counter. previewQueue only.
    private var fpsCountFrames: Int = 0
    private var fpsLastReport: CFTimeInterval = 0

    /// Held locked for the whole session. The device only keeps the
    /// configured frame rate while locked; unlocking silently reverts it
    /// (often to 30 fps on capture cards). Released in `stop()`.
    private var lockedDevice: AVCaptureDevice?

    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// Starts a video-only session and returns the capture size.
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
            // Unlock after stopRunning() so in-flight frames can flush.
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

        guard let videoDevice = AVCaptureDevice(uniqueID: cameraUniqueID) else {
            throw CaptureError.configurationFailed("Camera not found: \(cameraUniqueID)")
        }

        // Set the format after addInput. The session preset is applied
        // at addInput and would override an earlier format, capping the
        // frame rate. macOS has no `.inputPriority` preset.
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw CaptureError.configurationFailed("Cannot add video input")
        }
        session.addInput(videoInput)
        tryLockFormat(for: videoDevice)
        activeDimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)

        // Preview output
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        previewOutput.setSampleBufferDelegate(self, queue: previewQueue)
        guard session.canAddOutput(previewOutput) else {
            throw CaptureError.configurationFailed("Cannot add preview output")
        }
        session.addOutput(previewOutput)

        // Record output
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
                conn.automaticallyEnablesLowLightVideoNoiseReduction = false
                conn.isLowLightVideoNoiseReductionEnabled = lowLightNoiseReduction
            }
            print("CameraCaptureService: low-light noise reduction supported=\(lowLightNoiseReductionSupported) enabled=\(lowLightNoiseReductionSupported && lowLightNoiseReduction)")
        }
    }

    private func tryLockFormat(for device: AVCaptureDevice) {
        // Log every format, to see what the device exposes.
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

        // Rates are often reported slightly off (60 fps as 60.000240),
        // so match with a tolerance. 0.5 also covers 59.94.
        let targetRate: Double = 60.0
        let epsilon: Double    = 0.5
        let supportsTarget: (AVFrameRateRange) -> Bool = { range in
            range.minFrameRate <= targetRate + epsilon &&
            range.maxFrameRate >= targetRate - epsilon
        }

        // 4K60 needs about 6 Gbps uncompressed, more than USB 3.0 carries,
        // so it only holds 60 fps on a 10 Gb/s link. Hence the setting.
        let preferredResolutions = preferredResolution.searchOrder

        var picked: AVCaptureDevice.Format?
        for (w, h) in preferredResolutions {
            let matches = allFormats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width == w && d.height == h
                    && $0.videoSupportedFrameRateRanges.contains(where: supportsTarget)
            }
            // Some capture cards list a size twice. The one with the
            // higher top rate is the one that actually delivers 60 fps.
            let fastest = matches.max { a, b in
                (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                    < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            }
            if let fmt = fastest {
                picked = fmt
                break
            }
        }

        // Fallback: any format at the target rate.
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

        // Use the range's own minFrameDuration, not CMTime(1, 60). The
        // device matches durations by exact CMTime representation and
        // throws NSInvalidArgumentException on anything else.
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

        // Don't defer the unlock. The lock is held until `stop()`
        // (see `lockedDevice`).
        do {
            try device.lockForConfiguration()
            lockedDevice = device
            device.activeFormat = fmt
            device.activeVideoMinFrameDuration = range60.minFrameDuration
            device.activeVideoMaxFrameDuration = range60.minFrameDuration

            // Log what was applied, in case the session overrode it.
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

    /// FourCC code as a readable 4-character string, for logging.
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

            // Logs the delivered rate once a second, to tell a slow
            // source from a slow encoder. The queue is serial.
            fpsCountFrames += 1
            let now = CACurrentMediaTime()
            if fpsLastReport == 0 {
                fpsLastReport = now
            } else if now - fpsLastReport >= 1.0 {
                #if DEBUG
                let elapsed = now - fpsLastReport
                let observed = Double(fpsCountFrames) / elapsed
                print(String(format: "CameraCaptureService: observed %.2f fps (preview path, %d frames in %.3fs)", observed, fpsCountFrames, elapsed))
                #endif
                fpsCountFrames = 0
                fpsLastReport = now
            }
        } else if output === recordOutput {
            onRecordBuffer?(relabeledAsRec709(sampleBuffer))
        }
    }

    /// Reused while frames keep the same shape. recordQueue only.
    private var rec709Description: CMVideoFormatDescription?

    /// Tags the frame as Rec. 709. Some capture cards tag HDMI video as
    /// SMPTE 240M, which editors read as a different gamma. The writer
    /// reads color tags from the format description, so the buffer is
    /// rewrapped. Having the writer convert instead drops frames.
    /// Returns the original frame on failure.
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
