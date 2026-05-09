//
//  MainViewModel.swift
//  Recaptr
//
//  Phase 2: camera-source preview, owns DeviceCatalog + preview layer.
//  Phase 3: Recorder + recording state.
//  Phase 4 (2026-05-09): added selectedAudioSource. When set, audio is
//    captured + included in the recording. When nil, recording is video-only.
//

import Foundation
import Combine
import SwiftUI
import AVFoundation
import CoreMedia

@MainActor
final class MainViewModel: ObservableObject {

    @Published var catalog = DeviceCatalog()
    @Published var selectedMainSource: VideoSource?
    @Published var selectedAudioSource: AudioSource?

    @Published var isPreviewing = false
    @Published var isRecording = false
    @Published var status: String = "Idle"
    @Published var lastRecordedFile: URL?

    let previewSinkLayer = SampleBufferPreviewLayer(frame: .zero)

    private var cameraService: CameraCaptureService?
    private let recorder = Recorder()
    private var activeDims: CMVideoDimensions = .init(width: 0, height: 0)
    private var hasAudio = false  // Snapshot at preview-start; locked until stopPreview

    init() {
        Task { await self.refreshCatalog() }
    }

    func refreshCatalog() async {
        await catalog.refresh()
    }

    var availableMainSources: [VideoSource] {
        catalog.videoSources.filter { $0.kind == .camera }
    }

    var availableAudioSources: [AudioSource] {
        catalog.audioSources
    }

    func startPreview() async {
        stopPreview()

        guard let src = selectedMainSource else {
            status = "Select a camera source"
            return
        }
        guard src.kind == .camera, let cameraID = src.cameraUniqueID else {
            status = "Selected source is not a camera (Phase 5+)"
            return
        }

        let svc = CameraCaptureService()
        svc.onRecordBuffer = { [weak self] sb in self?.recorder.appendVideo(sb) }
        svc.onAudioBuffer  = { [weak self] sb in self?.recorder.appendAudio(sb) }

        let audioID = selectedAudioSource?.id

        do {
            let dims = try await svc.start(
                cameraUniqueID: cameraID,
                audioUniqueID: audioID,
                previewSink: previewSinkLayer
            )
            cameraService = svc
            activeDims = dims
            hasAudio = (audioID != nil)
            isPreviewing = true
            let audioLabel = hasAudio ? " + audio" : ""
            status = "Previewing — \(src.name) (\(dims.width)×\(dims.height))\(audioLabel)"
        } catch {
            status = "Camera/audio error: \(error.localizedDescription)"
        }
    }

    func stopPreview() {
        if isRecording {
            Task { await self.stopRecording() }
        }
        cameraService?.stop()
        cameraService = nil
        previewSinkLayer.flush()
        isPreviewing = false
        if status.hasPrefix("Previewing") { status = "Idle" }
    }

    func startRecording() async {
        guard isPreviewing else { status = "Start preview first"; return }
        guard activeDims.width > 0, activeDims.height > 0 else {
            status = "No active video dimensions"
            return
        }
        guard !isRecording else { return }

        do {
            let url = try await recorder.start(
                width: activeDims.width,
                height: activeDims.height,
                withAudio: hasAudio
            )
            isRecording = true
            lastRecordedFile = nil
            status = "Recording → \(url.lastPathComponent)"
        } catch {
            status = "Recorder error: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        let url = await recorder.stop()
        isRecording = false
        lastRecordedFile = url
        status = url.map { "Saved → \($0.lastPathComponent)" } ?? "Recording stopped (no file)"
    }
}
