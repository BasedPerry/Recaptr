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
//  Phase 5 follow-up (2026-05-11 evening): camera path framerate dig.
//    21-min RDR2 capture came in at 29.843 fps sustained, matching
//    Phase 4's 35-min stress test (29.87 fps). Three suspects:
//      (1) Windows PC outputting 30p over HDMI to the 4K X — Recaptr
//          can't manufacture frames the source doesn't deliver
//      (2) tryLockFormat picking a 30p format that misreports its
//          declared range — fixable here
//      (3) AVCaptureSession silently clamping — also fixable here
//    This pass adds: explicit format enumeration logging, tightened
//    picker that prefers 60p-locked formats over "up-to-60" formats,
//    post-lock state confirmation, and a live FPS counter on the
//    preview output that prints once per second. After a short test
//    capture, console output tells us which suspect is the culprit.
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

    private weak var previewSinkLayer: SampleBufferPreviewLayer?
    private var activeDimensions: CMVideoDimensions = .init(width: 0, height: 0)

    // Phase 5 follow-up — live FPS counter. Tracked on previewQueue
    // only (the delegate dispatches the preview output there serially,
    // so no concurrent access). Reset on each second boundary.
    private var fpsCountFrames: Int = 0
    private var fpsLastReport: CFTimeInterval = 0

    // Phase 5 follow-up (2026-05-11 evening, OBS source dive):
    // the device must remain LOCKED for the entire capture session,
    // not just during the format-set call. OBS's OBSAVCapture.m
    // configures via lockForConfiguration + activeFormat + frame
    // durations and never unlocks until removeDeviceInput. If we
    // unlock right after setting (the old `defer` pattern), the
    // device reverts and frame durations stop being honored —
    // empirically proven by Brandon: OBS-primed device delivered
    // 60fps to Recaptr, then dropped to 30 the moment OBS quit and
    // we re-locked-then-unlocked. Keep the lock for the session.
    private var lockedDevice: AVCaptureDevice?

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
            // Phase 5 follow-up — release the device lock that we've
            // held since configureSession. Pairs with the lock acquired
            // in tryLockFormat. Must happen AFTER stopRunning so the
            // session has a chance to flush in-flight frames.
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

        // Phase 5 follow-up (2026-05-11 evening, 3rd correction):
        // set activeFormat AFTER addInput, not before. On macOS, the
        // AVCaptureSession.sessionPreset (default .high) is applied
        // at addInput time and overrides whatever activeFormat we
        // had set on the device pre-input — silently capping the
        // framerate. (.inputPriority preset that iOS uses to opt out
        // of this isn't available on macOS, so we use the alternative
        // pattern: set the format last so nothing overrides it.)
        //
        // Apple docs (macOS): "If you change the active format on
        // an AVCaptureDevice that's providing input to a session,
        // the session will continue to use the input's active format."
        // Setting activeFormat AFTER the input is in place puts us
        // in that "session preserves the format" mode.
        //
        // Historical clue: this is the second half of the long-standing
        // "Recaptr records at 30fps regardless" finding. The first
        // half (Tahoe's strict CMTime validation) crashed when older
        // OSes had silently clamped. With both halves fixed, the
        // device's true 60p-capable formats should actually deliver
        // 60p, modulo source-side rate caps (Elgato 4K X → Windows).
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw CaptureError.configurationFailed("Cannot add video input")
        }
        session.addInput(videoInput)
        // NOW lock the format — after the input is in place.
        // tryLockFormat acquires the device lock and KEEPS IT held
        // for the session's lifetime (released in stop()). This is
        // the critical difference vs. our prior implementation — the
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
    }

    private func tryLockFormat(for device: AVCaptureDevice) {
        // Phase 5 follow-up — enumerate EVERY format the device reports,
        // grouped by resolution. Previously this was filtered to 1080p
        // for the picker; broadening the diagnostic to see whether
        // higher-resolution formats (notably 2160p / 4K) exist for
        // devices like the Elgato 4K X that advertise up to 2160p144
        // in their own software. If 4K formats exist here too, we
        // can lock to one; if they don't, AVFoundation is genuinely
        // unaware of them and we need a different attack path
        // (vendor-specific CMIO properties, USB protocol, etc.).
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
        // bandwidth-friendly resolutions in order. KEY FINDING
        // (2026-05-11 evening, AFTER the held-lock fix): the 4K X is
        // a USB 3.0 device with ~5 Gbps usable bandwidth. Raw 4K@60
        // NV12 needs ~6 Gbps and exceeds the wire — the device
        // truthfully drops to ~37fps for 4K. 1080p60 NV12 is ~1.5
        // Gbps and fits comfortably. The original 30fps cap from
        // before the held-lock fix masked this bandwidth ceiling.
        //
        // Resolution preference order: 1920×1080 first (always works,
        // every USB 3.0 capture card can deliver at 60), then larger
        // resolutions as fallbacks. A future iteration will expose a
        // UI format picker (OBS-style) so users with USB 3.2 Gen 2 or
        // Thunderbolt devices can opt into 4K60 explicitly. For now,
        // the default targets the resolution most creators actually
        // publish (YouTube/Twitch 1080p) without bandwidth surprises.
        //
        // Filter is epsilon-aware. Two range styles in the wild:
        //   - Discrete single-point ranges (Elgato 4K X: 240-240,
        //     ..., 60-60, ...). The device reports rates with
        //     CMTime-rational precision (e.g. "60fps" = 60.000240),
        //     so a strict `<= literal` comparison rejects them.
        //   - Continuous wide ranges (iPhone Continuity Camera: 1.0-60.0).
        // ε = 0.5 handles 60.000240 and covers NTSC 59.94 if we
        // target 60.
        let targetRate: Double = 60.0
        let epsilon: Double    = 0.5
        let supportsTarget: (AVFrameRateRange) -> Bool = { range in
            range.minFrameRate <= targetRate + epsilon &&
            range.maxFrameRate >= targetRate - epsilon
        }

        // Resolution preferences in priority order (USB bandwidth-aware).
        let preferredResolutions: [(Int32, Int32)] = [
            (1920, 1080),  // FHD — always USB 3.0 friendly at 60
            (2560, 1440),  // QHD — fits USB 3.0 at 60 (~2.7 Gbps NV12)
            (3440, 1440),  // UWQHD — fits USB 3.0 at 60 (~3.6 Gbps NV12)
            (3840, 2160),  // 4K — needs USB 3.2 Gen 2 for 60fps; on USB 3.0 will throttle
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

        // CRITICAL: use the range's reported minFrameDuration as-is.
        //
        // The 4K X on macOS Tahoe reports 60fps as a single-point range
        // (60.00 - 60.00) with frame duration encoded as CMTime(value:
        // 1000000, timescale: 60000240) — mathematically ~1/60.00024,
        // not exactly 1/60. AVCaptureDevice_Tundra (Tahoe's capture
        // device backing class) strictly validates the CMTime against
        // its discrete supported durations: CMTime(value: 1, timescale:
        // 60) throws NSInvalidArgumentException because it doesn't
        // match any of the device's reported durations exactly, even
        // though the rational value is "the same."
        //
        // The crash this prevents (2026-05-11 evening):
        //   *** -[AVCaptureDevice_Tundra setActiveVideoMinFrameDuration:]
        //   Not supported - Supported ranges: ( ... ),
        //   tried to set maxFrameRate to 60.000000 (1 / 60)
        //
        // Historical clue: pre-Tahoe AVFoundation appears to have
        // silently clamped invalid frame durations to the nearest
        // supported one (typically 30fps), which is the most plausible
        // cause of the long-standing "Recaptr records at 30fps even
        // though we asked for 60" finding (Phase 4 35-min stress test,
        // Phase 5 21-min RDR2 capture). Same root cause, different
        // surface symptom: Tahoe throws, older OS clamped.
        //
        // The fix: find a range containing 60, pull its minFrameDuration
        // (the shortest duration the range supports = the fastest rate,
        // which is 1/60 for any range whose max is exactly 60), and
        // pass that CMTime back to the device unchanged. Works for
        // both single-point ranges (60-60 → minDuration = 1/60) and
        // continuous ranges (1-60 → minDuration = 1/60 also).
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

        // CRITICAL: lock the device and HOLD the lock for the session's
        // lifetime. Do NOT defer unlock. Matches OBSAVCapture.m's
        // configureSession (mac-avcapture plugin lines 415-562): they
        // lockForConfiguration, set activeFormat + frame durations,
        // commitConfiguration — and never unlock until the device
        // input is being removed (line 201). The device only honors
        // the configured frame durations while it remains locked;
        // unlocking causes silent revert to default behavior (typically
        // 30fps for the 4K X). Stored in `lockedDevice` so stop()
        // can release it.
        do {
            try device.lockForConfiguration()
            lockedDevice = device
            device.activeFormat = fmt
            // Pass the range's CMTime as-is. The device validates by
            // identity/representation, not numerical equivalence.
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

            // Phase 5 follow-up — live FPS counter on the preview path.
            // Counts frames delivered by AVCaptureSession; prints once
            // per second. If this prints 30 while we're targeting 60,
            // the source is delivering 30 (Windows-side cause). If it
            // prints 60 but the recorded file is 30, the bottleneck is
            // downstream (encoder/muxer). Same delegate queue is
            // serial, so no concurrent access on the counters.
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
            onRecordBuffer?(sampleBuffer)
        }
    }
}
