//
//  CaptureOutline.swift
//  Recaptr
//
//  A thin outline around whatever a screen or window capture is
//  recording, so it's obvious which display or window is live (the
//  Recaptr window can sit on the display it's capturing). Green while
//  previewing, red while recording.
//
//  A borderless, click-through window above other apps. It never
//  appears in the capture: display captures exclude every Recaptr
//  window (see MainViewModel.startPreview), window captures only see
//  the one window, and the outline also opts out of screen sharing.
//

import AppKit
import SwiftUI

@MainActor
final class CaptureOutline {

    private var panel: NSPanel?
    private let model = OutlineModel()
    private var trackTimer: Timer?
    private var trackedWindow: CGWindowID?

    /// Outline a whole display.
    func show(display: CGDirectDisplayID) {
        stopTracking()
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { hide(); return }
        place(at: screen.frame)
    }

    /// Outline a window and follow it as it moves or resizes.
    func show(window: CGWindowID) {
        stopTracking()
        trackedWindow = window
        followWindow()
        // 10 Hz: smooth enough while dragging, negligible cost.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    func setRecording(_ recording: Bool) {
        model.recording = recording
    }

    func hide() {
        stopTracking()
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        trackedWindow = nil
    }

    private func followWindow() {
        guard let id = trackedWindow,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let primary = NSScreen.screens.first else {
            panel?.orderOut(nil)
            return
        }
        // Core Graphics window bounds are top-left based; AppKit is
        // bottom-left based on the primary screen.
        let rect = CGRect(x: bounds["X"] ?? 0,
                          y: primary.frame.height - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0),
                          width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        // A little outside the window so the line doesn't cover it.
        place(at: rect.insetBy(dx: -4, dy: -4))
    }

    private func place(at frame: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OutlineView(model: model))
        return panel
    }
}

@Observable
private final class OutlineModel {
    var recording = false
}

private struct OutlineView: View {
    let model: OutlineModel

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(model.recording ? Color.red : Color.signal, lineWidth: 3)
            .opacity(0.9)
            .animation(.easeInOut(duration: 0.25), value: model.recording)
            .allowsHitTesting(false)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
