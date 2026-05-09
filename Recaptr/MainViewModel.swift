//
//  MainViewModel.swift
//  Recaptr
//
//  Phase 2 (2026-05-09): fresh build, scoped to camera-source preview.
//  Owns the DeviceCatalog (single source of truth for device discovery)
//  and the SampleBufferPreviewLayer (single preview surface). Holds a
//  CameraCaptureService while previewing.
//
//  Per locked decision 1 (per-source main + facecam), this model's
//  selection state will grow in later phases:
//  - Phase 5 widens main-source filter to include `.screenDisplay` /
//    `.screenWindow` and gains a `ScreenCaptureService`.
//  - Phase 6 adds `selectedFacecam: VideoSource?` and an optional
//    second CameraCaptureService for the facecam track.
//
//  Phase 2 keeps it minimal: a single `selectedMainSource` filtered
//  to `.camera`, a single CameraCaptureService while previewing.
//

import Foundation
import Combine
import SwiftUI
import AVFoundation

@MainActor
final class MainViewModel: ObservableObject {

    /// Single source of truth for device discovery. Refreshed on init
    /// and on demand from the UI.
    @Published var catalog = DeviceCatalog()

    /// The user's chosen main video source. Phase 2 only honors
    /// `.camera` kind; Phase 5 widens this to include screen sources.
    @Published var selectedMainSource: VideoSource?

    /// True iff the camera service is running.
    @Published var isPreviewing = false

    /// User-facing status string surfaced in the UI.
    @Published var status: String = "Idle"

    /// Single preview surface owned by the model. Capture services
    /// push CMSampleBuffers to this layer directly.
    let previewSinkLayer = SampleBufferPreviewLayer(frame: .zero)

    private var cameraService: CameraCaptureService?

    init() {
        // Discovery on init so the picker has options as soon as
        // the window appears. .task on the WindowGroup is no longer
        // needed — this replaces it.
        Task { await self.refreshCatalog() }
    }

    func refreshCatalog() async {
        await catalog.refresh()
    }

    /// Cameras only for Phase 2. Phase 5 widens this filter.
    var availableMainSources: [VideoSource] {
        catalog.videoSources.filter { $0.kind == .camera }
    }

    func startPreview() async {
        // Idempotent — stop any prior session before starting a new one.
        stopPreview()

        guard let src = selectedMainSource else {
            status = "Select a camera source"
            return
        }
        guard src.kind == .camera, let cameraID = src.cameraUniqueID else {
            // Phase 2 only handles cameras. Other source kinds light up later.
            status = "Selected source is not a camera (Phase 5+)"
            return
        }

        let svc = CameraCaptureService()
        do {
            try await svc.start(cameraUniqueID: cameraID, previewSink: previewSinkLayer)
            cameraService = svc
            isPreviewing = true
            status = "Previewing — \(src.name)"
        } catch {
            status = "Camera error: \(error.localizedDescription)"
        }
    }

    func stopPreview() {
        cameraService?.stop()
        cameraService = nil
        previewSinkLayer.flush()
        isPreviewing = false
        if status.hasPrefix("Previewing") { status = "Idle" }
    }
}
