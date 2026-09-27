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
//  Frames are only handed to the display layer while the window can
//  actually be seen. Displaying a 1440p/4K frame 60 times a second is
//  the single biggest cost of the camera path (Core Animation
//  registering each frame, profiling 2026-09-27), and it's wasted when
//  the window is covered, minimized or on another Space, which is
//  common during a long take. Recording never goes through here.
//

import SwiftUI
import AVFoundation
import Synchronization

final class SampleBufferPreviewLayer: NSView {

    private let displayLayer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }()

    /// Whether the window is on screen. Read on capture queues.
    private let onScreen = Atomic<Bool>(true)
    private var windowObservers: [NSObjectProtocol] = []

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
        guard onScreen.load(ordering: .relaxed) else { return }
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOnScreen() }
            })
        }
        updateOnScreen()
    }

    private func updateOnScreen() {
        let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let was = onScreen.exchange(visible, ordering: .relaxed)
        // Coming back: drop whatever frame was left showing; the next
        // live one arrives within a frame.
        if visible, !was { displayLayer.sampleBufferRenderer.flush() }
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
