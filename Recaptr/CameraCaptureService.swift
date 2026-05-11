//
//  CameraCaptureService.swift
//  Recaptr
//
//  Phase 2: two-output video capture pattern (decision 5).
//  Phase 3: 1080p60 format lock + currentVideoDimensions return.
//  Phase 4 (2026-05-09): added optional audio input + AVCaptureAudioDataOutput.
//  Phase 4.5 (2026-05-09 evening): REMOVED the audio path. The new
//    AudioMixer (AVAudioEngine-based, multi-source, per-source gain)
//    owns all audio capture now. CameraCaptureService is back to
//    single-responsibility video.
//

import Foundation
import AVFoundation

final class CameraCaptureService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "recaptr.camera.session", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "recaptr.camera.preview", qos: .userInteractive)
    private let recordQueue  = DispatchQueue(label: "recaptr.camera.record",  qos: .userInitiated)

    private let previewOutput = AVCaptureVideoDataOutput()
    private let recordOutput  = AVCaptureVideoDataOutput()

    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// Configures + starts session for video only. Audio is handled
    /// by the separate AudioMixer (Phase 4.5).
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
        Self.tryLockFormat(for: videoDevice)
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw CaptureError.configurationFailed("Cannot add video input")
        }
        session.addInput(videoInput)
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
    }

    private static func tryLockFormat(for device: AVCaptureDevice) {
        let preferred = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supports60 = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 60.0 && 60.0 <= $0.maxFrameRate
            }
            return dims.width == 1920 && dims.height == 1080 && supports60
        }
        guard let fmt = preferred else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = fmt
            let dur = CMTime(value: 1, timescale: 60)
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
        } catch { /* fall through to device default */ }
    }

    // MARK: - Delegates

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === previewOutput {
            previewSinkLayer?.enqueue(sampleBuffer)
        } else if output === recordOutput {
            onRecordBuffer?(sampleBuffer)
        }
    }
}
