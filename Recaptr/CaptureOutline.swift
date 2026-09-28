//
//  CaptureOutline.swift
//  Recaptr
//
//  Click-through outline around the display or window being captured.
//  It never appears in the recording: display captures exclude Recaptr's
//  windows, and the panel opts out of sharing. The border is a CALayer
//  because a display-sized SwiftUI view kept the update loop busy.
//

import AppKit
import SwiftUI

@MainActor
final class CaptureOutline {

    private var panel: NSPanel?
    private let border = CALayer()
    private var recording = false
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
        // 10 Hz is smooth enough while dragging and costs little.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    func setRecording(_ recording: Bool) {
        self.recording = recording
        updateColor()
    }

    /// Green while previewing, red while recording.
    private func updateColor() {
        let color = recording ? NSColor.systemRed : NSColor(Color.signal)
        border.borderColor = color.withAlphaComponent(0.9).cgColor
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
        // CG window bounds are top-left origin; AppKit is bottom-left on the primary screen.
        let rect = CGRect(x: bounds["X"] ?? 0,
                          y: primary.frame.height - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0),
                          width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        // Just outside the window so the line doesn't cover it.
        place(at: rect.insetBy(dx: -4, dy: -4))
    }

    private func place(at frame: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            border.frame = CGRect(origin: .zero, size: frame.size)
            CATransaction.commit()
        }
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
        let view = NSView()
        view.wantsLayer = true
        border.borderWidth = 3
        border.cornerRadius = 10
        border.cornerCurve = .continuous
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        border.frame = view.bounds
        view.layer?.addSublayer(border)
        panel.contentView = view
        updateColor()
        return panel
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
