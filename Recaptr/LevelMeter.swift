//
//  LevelMeter.swift
//  Recaptr
//
//  Audio level meter drawn with Core Animation layers moved by a 30 Hz
//  timer. No SwiftUI state changes per tick, so no view rebuilds or layout.
//  Don't drive it from @State or a TimelineView; both re-lay-out the window.
//
//  The gradient spans the whole track, so red only shows near 0 dBFS.
//

import AppKit
import SwiftUI

struct LevelMeter: NSViewRepresentable {
    let levels: () -> (rms: Float, peak: Float)?
    /// False pauses updates, e.g. while the chrome is hidden.
    var active = true
    var vertical = true
    /// Track thickness (width when vertical, height when horizontal).
    var thickness: CGFloat = 8
    var showsPeak = true
    let label: String

    @Environment(\.colorSchemeContrast) private var contrast

    func makeNSView(context: Context) -> MeterView {
        MeterView(vertical: vertical, thickness: thickness, showsPeak: showsPeak)
    }

    func updateNSView(_ view: MeterView, context: Context) {
        view.levels = levels
        view.label = label
        view.active = active
        view.increasedContrast = contrast == .increased
    }

    /// dBFS (-60…0) → 0…1.
    static func normalize(_ dbfs: Float) -> CGFloat {
        CGFloat((min(max(dbfs, -60), 0) + 60) / 60)
    }

    static func readout(_ levels: (rms: Float, peak: Float)?) -> String {
        guard let peak = levels?.peak, peak > -100 else { return "—" }
        return String(format: "%+.0f dB", peak)
    }
}

final class MeterView: NSView {
    var levels: (() -> (rms: Float, peak: Float)?)?
    var label = "Level"
    var active = true { didSet { updateTimer() } }
    var increasedContrast = false { didSet { if increasedContrast != oldValue { updateColors() } } }

    private let vertical: Bool
    private let thickness: CGFloat
    private let showsPeak: Bool
    private let track = CALayer()
    private let gradient = CAGradientLayer()
    private let fillMask = CALayer()
    private let peak = CALayer()
    private var timer: Timer?
    private var lastReading: (rms: Float, peak: Float)?

    init(vertical: Bool, thickness: CGFloat, showsPeak: Bool) {
        self.vertical = vertical
        self.thickness = thickness
        self.showsPeak = showsPeak
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(gradient)
        gradient.mask = fillMask
        fillMask.backgroundColor = NSColor.black.cgColor
        if showsPeak { layer?.addSublayer(peak) }
        gradient.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
        gradient.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.6, 0.85, 1]
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let bar = barRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bar
        track.cornerRadius = thickness / 2
        gradient.frame = bar
        gradient.cornerRadius = thickness / 2
        CATransaction.commit()
        apply(lastReading)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func accessibilityValue() -> Any? {
        LevelMeter.readout(lastReading)
    }

    override func accessibilityLabel() -> String? { label }

    // MARK: - Private

    /// The track, centered across the view's thickness.
    private var barRect: CGRect {
        vertical
            ? CGRect(x: (bounds.width - thickness) / 2, y: 0, width: thickness, height: bounds.height)
            : CGRect(x: 0, y: (bounds.height - thickness) / 2, width: bounds.width, height: thickness)
    }

    private func updateTimer() {
        let shouldRun = active && window != nil
        if shouldRun, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // A few ms of slack lets macOS batch wake-ups.
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldRun {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        if let window, !window.occlusionState.contains(.visible) { return }
        apply(levels?())
    }

    private func apply(_ reading: (rms: Float, peak: Float)?) {
        lastReading = reading
        let bar = barRect
        let rms = LevelMeter.normalize(reading?.rms ?? -120)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillMask.frame = vertical
            ? CGRect(x: 0, y: 0, width: bar.width, height: bar.height * rms)
            : CGRect(x: 0, y: 0, width: bar.width * rms, height: bar.height)
        if showsPeak {
            if let p = reading?.peak, p > -100 {
                peak.isHidden = false
                let f = LevelMeter.normalize(p)
                peak.frame = vertical
                    ? CGRect(x: bar.minX - 1, y: max(0, bar.height * f - 1.5), width: thickness + 2, height: 1.5)
                    : CGRect(x: max(0, bar.width * f - 1.5), y: bar.minY - 1, width: 1.5, height: thickness + 2)
            } else {
                peak.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let trackColor: NSColor = increasedContrast ? .secondaryLabelColor : .tertiaryLabelColor
            track.backgroundColor = trackColor.cgColor
            gradient.colors = [Color.signal, .signal, .warningAmber, .red].map { NSColor($0).cgColor }
            peak.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        }
    }
}
