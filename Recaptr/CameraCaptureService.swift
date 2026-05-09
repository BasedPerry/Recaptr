//
//  CameraCaptureService.swift
//  Recaptr
//
//  Phase 2 (2026-05-09): fresh build against shipping macOS Tahoe.
//  Implements locked decision 5 — separate preview + record paths via
//  two AVCaptureVideoDataOutputs on the same AVCaptureSession. Output A
//  feeds the preview layer; Output B's `onRecordBuffer` callback is
//  exposed but left unset until Phase 3 wires the recorder.
//
//  Reference (not lifted): Dev/BackupCapture/Sources/CameraCaptureService.swift.
//  Differences from reference:
//  - Two outputs instead of one (decision 5)
//  - Session configuration dispatched onto a dedicated serial queue so
//    the UI doesn't block on startRunning()
//  - No 4K hardcoded format — uses device default. Phase 3 will pick
//    a specific format against encoder needs (consult CaptureDeviceFormat
//    catalog from Models.swift)
//

import Foundation
import AVFoundation

/// Camera capture pipeline. Wraps an AVCaptureSession with two
/// AVCaptureVideoDataOutputs:
/// - Output A (preview): pushes CMSampleBuffers directly to the held
///   `previewSinkLayer` reference. Drops late frames for low latency.
/// - Output B (record): exposes `onRecordBuffer` callback, set by the
///   recorder in Phase 3. Does not drop frames.
///
/// `@unchecked Sendable` is honest here — all session mutations are
/// dispatched onto the serial `sessionQueue`, and delegate callbacks
/// fire on dedicated `previewQueue` / `recordQueue`.
final class CameraCaptureService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "recaptr.camera.session", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "recaptr.camera.preview", qos: .userInteractive)
    private let recordQueue  = DispatchQueue(label: "recaptr.camera.record",  qos: .userInitiated)

    private let previewOutput = AVCaptureVideoDataOutput()
    private let recordOutput  = AVCaptureVideoDataOutput()

    private weak var previewSinkLayer: SampleBufferPreviewLayer?

    /// Called from the record queue with each captured buffer.
    /// Phase 3 wires the recorder here.
    var onRecordBuffer: ((CMSampleBuffer) -> Void)?

    /// Configures the session and starts it running. Returns once
    /// `startRunning()` has been dispatched; actual frames begin a
    /// moment later as the device warms up.
    func start(cameraUniqueID: String, previewSink: SampleBufferPreviewLayer) async throws {
        self.previewSinkLayer = previewSink
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(cameraUniqueID: cameraUniqueID)
                    self.session.startRunning()
                    cont.resume()
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

        // Idempotent — make start() safe to call after a prior session
        // (e.g. user picks a different camera and hits Start again).
        session.inputs.forEach  { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice(uniqueID: cameraUniqueID) else {
            throw CaptureError.configurationFailed("Camera not found for uniqueID \(cameraUniqueID)")
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.configurationFailed("AVCaptureDeviceInput init failed: \(error.localizedDescription)")
        }

        guard session.canAddInput(input) else {
            throw CaptureError.configurationFailed("Cannot add input for \(device.localizedName)")
        }
        session.addInput(input)

        // Default format. Phase 3 will pick a specific format against
        // encoder needs once Recorder lands.
        session.sessionPreset = .high

        // ── Output A — preview path (low latency, drops late frames)
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        previewOutput.setSampleBufferDelegate(self, queue: previewQueue)
        guard session.canAddOutput(previewOutput) else {
            throw CaptureError.configurationFailed("Cannot add preview output")
        }
        session.addOutput(previewOutput)

        // ── Output B — record path. Doesn't drop frames; recorder
        // depends on continuous sample buffers. Same pixel format as
        // preview so the device input produces both streams without
        // re-conversion.
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

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    //
    // Fires from previewQueue or recordQueue depending on which output
    // produced the buffer. Distinguished by output identity.

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
