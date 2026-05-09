//
//  SampleBufferPreviewView.swift
//  Recaptr
//
//  Phase 1 (2026-05-09): lifted from BackupCapture, Representable
//    half temporarily commented (depended on MainViewModel which
//    didn't yet exist).
//  Phase 2 (2026-05-09): MainViewModel landed — Representable
//    re-enabled. enqueue/flush patched to use macOS 15+
//    `sampleBufferRenderer` API (the AVSampleBufferDisplayLayer
//    methods deprecated in macOS 15).
//

import SwiftUI
import AVFoundation

final class SampleBufferPreviewLayer: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        self.layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        displayLayer.frame = self.bounds
    }

    /// Push a sample buffer to the underlying display layer.
    /// `AVSampleBufferVideoRenderer.enqueue(_:)` is documented
    /// thread-safe — capture services call this from their preview
    /// dispatch queue, NOT main.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    /// Clear pending buffers from the renderer.
    func flush() {
        displayLayer.sampleBufferRenderer.flush()
    }
}

struct SampleBufferPreviewRepresentable: NSViewRepresentable {
    @ObservedObject var vm: MainViewModel

    func makeNSView(context: Context) -> SampleBufferPreviewLayer {
        vm.previewSinkLayer
    }

    func updateNSView(_ nsView: SampleBufferPreviewLayer, context: Context) { }
}
