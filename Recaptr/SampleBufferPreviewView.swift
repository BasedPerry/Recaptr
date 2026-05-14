//
//  SampleBufferPreviewView.swift
//  Recaptr
//
//  AVSampleBufferDisplayLayer-backed preview surface. Capture
//  services push `CMSampleBuffer`s through `enqueue(_:)`; the layer
//  renders them at native resolution.
//
//  The display layer is registered as the view's *backing* layer
//  (via `makeBackingLayer()`) rather than added as a sublayer. This
//  guarantees AppKit sizes and positions the layer automatically as
//  the view participates in normal layout, and avoids timing issues
//  where a sublayer attached during `init` may not see the host
//  view's backing CALayer ready yet on macOS 26+.
//

import SwiftUI
import AVFoundation

final class SampleBufferPreviewLayer: NSView {

    private let displayLayer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returns the AVSampleBufferDisplayLayer as the view's backing
    /// layer. AppKit calls this when `wantsLayer == true`.
    override func makeBackingLayer() -> CALayer {
        return displayLayer
    }

    /// Push a sample buffer to the underlying renderer. Thread-safe
    /// per Apple's documentation; capture services call this from
    /// their preview dispatch queues, not the main thread.
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
