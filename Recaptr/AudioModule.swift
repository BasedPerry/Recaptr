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
//  Meters are Core Animation layers updated directly (LevelMeter.swift),
//  reading levels straight from the view model, so the card never
//  rebuilds or re-lays-out per tick. They pause while the chrome is
//  faded out.
//

import SwiftUI

struct AudioModule: View {

    @EnvironmentObject var vm: MainViewModel

    @State private var isDraggingVolume = false
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// False while the floating chrome is faded out: meters pause.
    @Environment(\.chromeVisible) private var chromeVisible

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
                       readout: .text(volumeReadout), help: "Monitor volume") {
                    volumeTrack
                }
                column(icon: "waveform", readout: .level { vm.sourceLevels() }, help: "Source audio level") {
                    LevelMeter(levels: { vm.sourceLevels() }, active: chromeVisible,
                               thickness: trackWidth, label: "Source level")
                        .accessibilityIdentifier("sourceLevel")
                }
                if vm.hasMic {
                    column(icon: "mic.fill", readout: .level { vm.micLevels() }, help: "Mic level") {
                        LevelMeter(levels: { vm.micLevels() }, active: chromeVisible,
                                   thickness: trackWidth, label: "Mic level")
                            .accessibilityIdentifier("micLevel")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio")
        .accessibilityIdentifier("audioPill")
    }

    // MARK: - Layout pieces

    /// One pill column: control or meter, then an icon, then the
    /// number (shown on hover only; the space is kept so the pill
    /// doesn't resize).
    private func column<Content: View>(icon: String, readout: Readout, help: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
                .frame(width: columnWidth, height: trackHeight)
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(height: 14)
            ReadoutText(readout: readout, active: showNumbers && chromeVisible)
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

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// Toggle monitor on/off (button and ⌘K).
    func toggleMonitor() {
        vm.monitorEnabled.toggle()
    }
}

/// What a column shows under its icon on hover.
private enum Readout {
    case text(String)
    case level(() -> (rms: Float, peak: Float)?)
}

/// Hover number. Level readouts refresh at 10 Hz, only while shown.
private struct ReadoutText: View {
    let readout: Readout
    let active: Bool

    var body: some View {
        switch readout {
        case .text(let text):
            label(text)
        case .level(let levels):
            // The timeline only exists while the number is showing.
            if active {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    label(Self.format(levels()))
                }
            } else {
                label("")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(weight: .medium, size: 9).swiftUI)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    static func format(_ levels: (rms: Float, peak: Float)?) -> String {
        guard let peak = levels?.peak, peak > -100 else { return "—" }
        return String(format: "%+.0f", peak)
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
