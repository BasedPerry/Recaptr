//
//  Models.swift
//  Recaptr
//
//  Source descriptors, device format info and CaptureError.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - Source descriptors

/// A screen or window from ScreenCaptureKit, or an AVCaptureDevice camera.
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

/// Name matching used to prefer a capture card at startup. Capture cards and
/// USB webcams are both `.external`, so the device type can't tell them apart.
extension VideoSource {

    /// The name matches a known capture card maker or product line.
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
}

/// A capturable audio source. `id` is the CoreAudio device UID.
struct AudioSource: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Errors from the capture stack.
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

/// A capture device and the formats it supports.
struct CaptureDeviceInfo: Identifiable {
    var id: String { uniqueID }
    let name: String
    let uniqueID: String
    let formats: [CaptureDeviceFormat]
}

/// One resolution, frame-rate range and pixel format of an `AVCaptureDevice`.
struct CaptureDeviceFormat {
    let resolution: CMVideoDimensions
    let minFrameRate: Double
    let maxFrameRate: Double
    let pixelFormatType: FourCharCode
}
