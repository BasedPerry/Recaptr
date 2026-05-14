//
//  Models.swift
//  Recaptr
//
//  Shared value types: video / audio source descriptors used by the
//  device catalog and capture services, per-format diagnostic structs
//  consumed by the encoder config, and the top-level CaptureError.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - Source descriptors

/// A capturable video source. Either a screen / window from
/// ScreenCaptureKit or an AVCaptureDevice camera.
struct VideoSource: Identifiable, Hashable {
    enum Kind: String { case screenDisplay, screenWindow, camera }
    let id: String
    let name: String
    let kind: Kind
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?
    let cameraUniqueID: String?
}

// MARK: - Camera classification heuristics

/// Heuristics used by startup auto-source selection to prefer a
/// capture card over a built-in webcam or Continuity Camera.
///
/// AVFoundation does not expose a flag identifying capture cards —
/// the underlying `AVCaptureDevice.deviceType` is `.external` for
/// both capture cards and most USB webcams — so this matches on
/// common manufacturer and product name fragments. False positives
/// just mean a non-capture-card webcam might be auto-picked, which
/// is still preferable to the alternative of no default source.
extension VideoSource {

    /// True if the camera's name matches a known video-capture-card
    /// manufacturer or product line.
    var isCameraCaptureCard: Bool {
        guard kind == .camera else { return false }
        let needles = [
            "elgato",
            "magewell",
            "avermedia",
            "blackmagic",
            "aja",
            "live gamer",
            "usb capture",
            "hdmi capture",
            "video capture"
        ]
        let lower = name.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// True if the camera is a Continuity Camera (iPhone or iPad
    /// acting as a macOS webcam). Detected via name match.
    var isContinuityCamera: Bool {
        guard kind == .camera else { return false }
        let lower = name.lowercased()
        return lower.contains("iphone camera") ||
               lower.contains("ipad camera") ||
               lower.contains("continuity camera")
    }
}

/// A capturable audio source. `id` is the CoreAudio device UID.
struct AudioSource: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Top-level error type surfaced from the capture stack.
enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case configurationFailed(String)
    case writerFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Permission denied. Enable camera/microphone/screen capture in Settings."
        case .configurationFailed(let m): return "Configuration failed: \(m)"
        case .writerFailed(let m): return "Recording failed: \(m)"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

// MARK: - Per-format diagnostics

/// A capture device's full per-format catalog. Populated during
/// device discovery and consumed by the encoder configuration to
/// choose settings against the formats the device supports.
struct CaptureDeviceInfo: Identifiable {
    var id: String { uniqueID }
    let name: String
    let uniqueID: String
    let formats: [CaptureDeviceFormat]
}

/// One resolution × frame-rate range × pixel format combination
/// exposed by an `AVCaptureDevice`.
struct CaptureDeviceFormat {
    let resolution: CMVideoDimensions
    let minFrameRate: Double
    let maxFrameRate: Double
    let pixelFormatType: FourCharCode
}
