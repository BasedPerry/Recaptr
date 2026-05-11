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
//  Phase 4 hardening (2026-05-09 evening): preview was rendering
//    black even though both video and audio were landing in the
//    recorded file (v=5,220 a=16,330 drop=0/0 at 02:53 confirmed).
//    Two probable culprits in the old layout:
//      (a) `wantsLayer = true` followed by `self.layer?.addSublayer(...)`
//          in init isn't synchronous on macOS 26 — the backing
//          CALayer often isn't available yet, so the displayLayer
//          never attached.
//      (b) `displayLayer.frame = self.bounds` was applied only in
//          `layout()`, which SwiftUI's NSViewRepresentable doesn't
//          reliably trigger after the initial sizing.
//    Fix: make AVSampleBufferDisplayLayer the view's *backing*
//    layer via `makeBackingLayer()`. Then it's guaranteed in the
//    hierarchy and AppKit auto-sizes it with the view. No sublayer
//    plumbing, no layout() dependency.
//

import SwiftUI
import AVFoundation

final class SampleBufferPreviewLayer: NSView {
    /// The display layer is the view's backing layer — see header.
    private let displayLayer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        // Black behind letterboxing so the area is visually distinct
        // from "preview is broken."
        l.backgroundColor = NSColor.black.cgColor
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Backing layer is set lazily by AppKit by calling makeBackingLayer().
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError() }

    /// AppKit asks for a backing layer when `wantsLayer == true`.
    /// Returning the AVSampleBufferDisplayLayer here makes it the
    /// canonical layer for the view — sized + positioned by the
    /// AppKit/SwiftUI layout system automatically.
    override func makeBackingLayer() -> CALayer {
        return displayLayer
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
