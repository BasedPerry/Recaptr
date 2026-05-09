//
//  Models.swift
//  Recaptr
//
//  Phase 1 (2026-05-09): merged file.
//  - VideoSource / AudioSource / CaptureError lifted unchanged from
//    Dev/BackupCapture/Sources/Models.swift. Consumed by DeviceCatalog
//    and (in Phase 2+) by MainViewModel and the capture services.
//  - CaptureDeviceInfo / CaptureDeviceFormat preserved from the prior
//    Dev/Recaptr/Recaptr/Models.swift created during Phase 0. They
//    capture per-format diagnostics (resolution × frame-rate × pixel
//    format) that DeviceCatalog does not currently expose. Held here
//    for Phase 3 — H.264 encoder configuration needs to know what
//    formats the 4K X actually supports. Will be populated by a method
//    on DeviceCatalog (or a small dedicated FormatCatalog) when Phase 3
//    needs them.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - Source orchestration (lifted from BackupCapture)

struct VideoSource: Identifiable, Hashable {
    enum Kind: String { case screenDisplay, screenWindow, camera }
    let id: String
    let name: String
    let kind: Kind
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?
    let cameraUniqueID: String?
}

struct AudioSource: Identifiable, Hashable {
    let id: String
    let name: String
}

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

// MARK: - Per-format diagnostics (Phase 0 → Phase 3 encoder config)

/// A capture device's full per-format catalog. Populated during device
/// discovery and consumed in Phase 3 to choose H.264 encoder settings
/// against the formats the device actually supports.
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
