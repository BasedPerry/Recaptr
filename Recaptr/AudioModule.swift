//
//  AudioModule.swift
//  Recaptr
//
//  Right-edge floating audio card: the audio controls you need
//  mid-session, readable at a glance.
//
//    Top       Monitor toggle (headphones). ⌘K does the same.
//    Columns   Monitor volume (drag), source level, mic level (only
//              when a commentary mic is chosen). Each column has an
//              icon underneath instead of a text label.
//    Hover     Numbers (volume %, peak dB per meter) fade in while the
//              pointer is over the pill or the volume is being dragged,
//              so the resting pill is controls and meters only.
//
//  Gains and device choice live in Settings (set-and-forget).
//
//  Meters poll the view model at 30 Hz into local @State so they feel
//  continuous without republishing view-model state.
//

import SwiftUI
import Combine

struct AudioModule: View {

    @EnvironmentObject var vm: MainViewModel

    @State private var source = MeterReading()
    @State private var mic = MeterReading()
    @State private var isDraggingVolume = false
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private let meterTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private let trackHeight: CGFloat = 150
    private let trackWidth: CGFloat = 8
    private let columnWidth: CGFloat = 26

    /// Monitor volume range. Matches `MainViewModel.monitorVolume` (0…1.5).
    private let volumeMin: Double = 0
    private let volumeMax: Double = 1.5

    private var showNumbers: Bool { isHovering || isDraggingVolume }

    var body: some View {
        VStack(spacing: 10) {
            monitorToggle

            HStack(alignment: .bottom, spacing: 4) {
                column(icon: vm.monitorEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                       readout: volumeReadout, help: "Monitor volume") {
                    volumeTrack
                }
                column(icon: "waveform", readout: source.readout, help: "Source audio level") {
                    meter(source, label: "Source level", id: "sourceLevel")
                }
                if vm.hasMic {
                    column(icon: "mic.fill", readout: mic.readout, help: "Mic level") {
                        meter(mic, label: "Mic level", id: "micLevel")
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        // A card, not a capsule: with two or three columns the pill
        // got wide enough that its fully rounded ends looked bloated.
        .recaptrGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showNumbers)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: vm.hasMic)
        .onReceive(meterTimer) { _ in
            source.update(vm.sourceLevels())
            mic.update(vm.micLevels())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio")
        .accessibilityIdentifier("audioPill")
    }

    // MARK: - Layout pieces

    /// One pill column: control or meter, then an icon, then the
    /// number (shown on hover only; the space is kept so the pill
    /// doesn't resize).
    private func column<Content: View>(icon: String, readout: String, help: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
                .frame(width: columnWidth, height: trackHeight)
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(height: 14)
            Text(readout)
                .font(BrandFont.mono(weight: .medium, size: 9).swiftUI)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: columnWidth + 6, height: 11)
                .opacity(showNumbers ? 1 : 0)
                .accessibilityHidden(true)
        }
        .help(help)
    }

    /// Click to toggle monitor on/off. Also bound to ⌘K.
    private var monitorToggle: some View {
        Button(action: toggleMonitor) {
            Image(systemName: vm.monitorEnabled ? "headphones" : "headphones.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(vm.monitorEnabled ? AnyShapeStyle(Color.signal)
                                                   : AnyShapeStyle(.primary))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(vm.monitorEnabled ? Color.signal.opacity(0.18) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!vm.canMonitor)
        .help(monitorHelp)
        .accessibilityLabel("Monitor")
        .accessibilityValue(vm.monitorEnabled ? "On" : "Muted")
        .accessibilityIdentifier("monitorToggle")
    }

    /// Screen and window captures monitor the mic only, since the
    /// system audio is already playing through the speakers.
    private var monitorHelp: String {
        guard vm.canMonitor else {
            return "Nothing to monitor: system audio already plays through your speakers. Choose a mic to hear it here."
        }
        let isCamera = vm.selectedMainSource?.kind == .camera
        if vm.monitorEnabled { return "Mute monitor (⌘K)" }
        return isCamera ? "Listen to source audio (⌘K)" : "Listen to your mic (⌘K)"
    }

    /// Draggable monitor volume. Dims (but stays draggable) while the
    /// monitor is muted so the level can be set in advance.
    private var volumeTrack: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fill = CGFloat(clamp01(volumeFraction))
            let isLive = vm.monitorEnabled

            ZStack(alignment: .bottom) {
                trackBackground

                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .restore, location: 0.0),
                            .init(color: .violet,  location: 0.6),
                            .init(color: .signal,  location: 1.0),
                        ],
                        startPoint: .bottom, endPoint: .top))
                    .frame(width: trackWidth, height: h)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: h * fill)
                    }
                    .opacity(isLive ? 1.0 : 0.35)

                Circle()
                    .fill(.primary)
                    .frame(width: 10, height: 10)
                    .opacity(isLive ? 1.0 : 0.5)
                    .position(x: geo.size.width / 2, y: max(5, h - h * fill))
                    .shadow(radius: 1)
                    .allowsHitTesting(false)

                // Full-column hit target so the thin track is easy to grab.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let f = max(0, min(1, 1 - (value.location.y / h)))
                                vm.monitorVolume = volumeMin + (volumeMax - volumeMin) * Double(f)
                                if !isDraggingVolume { isDraggingVolume = true }
                            }
                            .onEnded { _ in isDraggingVolume = false }
                    )
            }
            .frame(maxWidth: .infinity)
        }
        // Exposed to accessibility as a real slider.
        .accessibilityRepresentation {
            Slider(value: $vm.monitorVolume, in: volumeMin...volumeMax, step: 0.05) {
                Text("Monitor volume")
            }
            .accessibilityValue("\(Int(vm.monitorVolume * 100)) percent"
                                + (vm.monitorEnabled ? "" : ", muted"))
        }
        .accessibilityIdentifier("monitorVolume")
    }

    /// Read-only level column: RMS fills bottom-up, a thin tick marks
    /// the recent peak.
    private func meter(_ reading: MeterReading, label: String, id: String) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                trackBackground
                // Gradient spans the whole track and is revealed from
                // the bottom, so red only shows near 0 dBFS.
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .signal,       location: 0.0),
                            .init(color: .signal,       location: 0.6),
                            .init(color: .warningAmber, location: 0.85),
                            .init(color: .red,          location: 1.0),
                        ],
                        startPoint: .bottom, endPoint: .top))
                    .frame(width: trackWidth, height: h)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: h * CGFloat(normalize(reading.rms)))
                    }
                Rectangle()
                    .fill(.primary)
                    .frame(width: trackWidth + 2, height: 1.5)
                    .position(x: geo.size.width / 2, y: max(2, h - h * CGFloat(normalize(reading.peak))))
                    .opacity(reading.peak > -100 ? 0.85 : 0)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(reading.readout)
        .accessibilityIdentifier(id)
    }

    /// Empty-track fill; one step stronger under Increase Contrast.
    private var trackBackground: some View {
        Capsule()
            .fill(contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: trackWidth)
    }

    // MARK: - Helpers

    private var volumeFraction: Double {
        (vm.monitorVolume - volumeMin) / (volumeMax - volumeMin)
    }

    private var volumeReadout: String {
        vm.monitorEnabled ? "\(Int(vm.monitorVolume * 100))%" : "OFF"
    }

    /// dBFS (-60…0) → 0…1.
    private func normalize(_ dbfs: Float) -> Float {
        (min(max(dbfs, -60), 0) + 60) / 60
    }

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// Toggle monitor on/off (button and ⌘K).
    func toggleMonitor() {
        vm.monitorEnabled.toggle()
    }
}

/// Smoothed meter state. Falls back toward silence when the source
/// stops so a meter never freezes at its last value.
private struct MeterReading {
    var rms: Float = -120
    var peak: Float = -120

    mutating func update(_ levels: (rms: Float, peak: Float)?) {
        if let levels {
            rms = levels.rms
            peak = levels.peak
        } else {
            if rms > -100 { rms -= 2 }
            if peak > -100 { peak -= 2 }
        }
    }

    var readout: String {
        peak > -100 ? String(format: "%+.0f", peak) : "—"
    }
}

// MARK: - Preview

// Debug only: ChromePreviewStage (Glass.swift) is a debug helper.
#if DEBUG

#Preview("Audio Module, Dark") {
    ChromePreviewStage { AudioModule().environmentObject(MainViewModel()) }
        .frame(width: 600, height: 400)
        .preferredColorScheme(.dark)
}

#Preview("Audio Module, Light") {
    ChromePreviewStage { AudioModule().environmentObject(MainViewModel()) }
        .frame(width: 600, height: 400)
        .preferredColorScheme(.light)
}
#endif
