//
//  SampleBufferPreviewView.swift
//  Recaptr
//
//  Live preview backed by AVSampleBufferDisplayLayer.
//

import SwiftUI
import AVFoundation
import Synchronization

/// Preview view. Frames are skipped while the window isn't visible,
/// since displaying them is the costliest part of the camera path.
/// Recording doesn't go through here.
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

    /// A backing layer, not a sublayer, so AppKit handles its layout.
    override func makeBackingLayer() -> CALayer {
        return displayLayer
    }

    /// Thread-safe. Called from the capture services' preview queues.
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
        // Becoming visible: drop the stale frame left showing.
        if visible, !was { displayLayer.sampleBufferRenderer.flush() }
    }

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
