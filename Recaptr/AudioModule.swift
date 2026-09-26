//
//  AudioModule.swift
//  Recaptr
//
//  Right-edge floating audio pill. Surfaces the three audio
//  concerns that need to be reachable mid-session:
//
//    1. Monitor toggle — am I hearing the input in my headphones
//    2. Monitor volume — how loud the monitor is
//    3. Input VU       — read-only level meter confirming mic is hot
//
//  Mic gain lives in the Settings window (set-and-forget). The
//  pill carries the dynamic controls.
//
//  VU update rate: the AudioMixer computes RMS + peak per buffer
//  (~21ms cadence) and the mixerStats @Published value updates at
//  1Hz. This view polls the mixer at 30Hz via a Timer publisher
//  and stores levels in local @State so the meter feels continuous
//  without triggering global re-renders.
//

import SwiftUI
import Combine

struct AudioModule: View {

    @EnvironmentObject var vm: MainViewModel

    @State private var rmsDbfs: Float = -120
    @State private var peakDbfs: Float = -120
    @State private var isDraggingVolume: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// 30Hz timer publisher driving VU updates. Auto-connected so
    /// it runs while the view is mounted, fires on main.
    private let vuTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    // Dimensions
    private let baseWidth: CGFloat = 64
    private let totalHeight: CGFloat = 280
    private let trackHeight: CGFloat = 160
    private let trackColumnWidth: CGFloat = 8

    /// Monitor volume range. Matches `MainViewModel.monitorVolume` (0…1.5).
    private let volumeMin: Double = 0
    private let volumeMax: Double = 1.5

    var body: some View {
        audioBody
        .frame(width: baseWidth + (isDraggingVolume ? 4 : 0))
        .frame(height: totalHeight)
        .padding(.vertical, 12)
        .recaptrGlass()
        .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.18),
                   value: isDraggingVolume)
        .onReceive(vuTimer) { _ in
            if let levels = vm.currentAudioLevels() {
                rmsDbfs = levels.rms
                peakDbfs = levels.peak
            } else {
                // Mixer not running — decay toward floor so the
                // meter doesn't stick at the last value.
                if rmsDbfs > -100 { rmsDbfs -= 2 }
                if peakDbfs > -100 { peakDbfs -= 2 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio")
    }

    // MARK: - Body layout

    private var audioBody: some View {
        VStack(spacing: 8) {
            sectionLabel("AUDIO")

            monitorToggle

            HStack(spacing: 10) {
                volumeTrack
                vuTrack
            }
            .frame(height: trackHeight)

            VStack(spacing: 2) {
                Text(volumeReadout)
                    .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
                    .foregroundStyle(vm.monitorEnabled ? .primary : .tertiary)
                Text(peakReadout)
                    .font(BrandFont.mono(weight: .regular, size: 9).swiftUI)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    /// Click to toggle monitor on/off. Also bound to a window-level
    /// keyboard shortcut in `ContentViewNext`.
    private var monitorToggle: some View {
        Button(action: toggleMonitor) {
            Image(systemName: vm.monitorEnabled ? "headphones" : "headphones.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(vm.monitorEnabled ? AnyShapeStyle(Color.signal)
                                                   : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(vm.monitorEnabled ? Color.signal.opacity(0.18) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(vm.monitorEnabled ? "Mute monitor" : "Unmute monitor")
        .accessibilityLabel("Monitor")
        .accessibilityValue(vm.monitorEnabled ? "On" : "Muted")
        .accessibilityIdentifier("monitorToggle")
    }

    /// Draggable monitor volume column. Dims (but stays draggable)
    /// when monitor is muted so the user can pre-position the level
    /// for when monitor comes back on.
    private var volumeTrack: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fill = CGFloat(clamp01(volumeFraction))
            let isLive = vm.monitorEnabled

            ZStack(alignment: .bottom) {
                trackBackground

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.restore, location: 0.0),
                                .init(color: Color.violet,  location: 0.6),
                                .init(color: Color.signal,  location: 1.0),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: trackColumnWidth, height: h * fill)
                    .opacity(isLive ? 1.0 : 0.35)
                    .animation(.linear(duration: 0.06), value: vm.monitorVolume)
                    .animation(.easeOut(duration: 0.2), value: isLive)

                Circle()
                    .fill(.primary)
                    .frame(width: 10, height: 10)
                    .opacity(isLive ? 1.0 : 0.5)
                    .position(
                        x: geo.size.width / 2,
                        y: max(5, h - h * fill)
                    )
                    .shadow(radius: 1)
                    .allowsHitTesting(false)

                // Wider invisible hit target so the user doesn't have
                // to land exactly on the 8pt-wide track.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let f = 1 - (value.location.y / h)
                                let clamped = max(0, min(1, f))
                                vm.monitorVolume = volumeMin + (volumeMax - volumeMin) * Double(clamped)
                                if !isDraggingVolume { isDraggingVolume = true }
                            }
                            .onEnded { _ in isDraggingVolume = false }
                    )
            }
        }
        .frame(maxWidth: .infinity)
        // Expose the custom track to accessibility as a real slider,
        // so VoiceOver, Accessibility Inspector, and UI tests can read
        // and adjust the monitor volume.
        .accessibilityRepresentation {
            Slider(value: $vm.monitorVolume, in: volumeMin...volumeMax, step: 0.05) {
                Text("Monitor volume")
            }
            .accessibilityValue("\(Int(vm.monitorVolume * 100)) percent"
                                + (vm.monitorEnabled ? "" : ", muted"))
        }
        .accessibilityIdentifier("monitorVolume")
    }

    /// Read-only VU column. RMS fills bottom-up; a thin peak tick
    /// floats above the RMS fill.
    private var vuTrack: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let rmsFill = CGFloat(normalize(rmsDbfs))
            let peakFill = CGFloat(normalize(peakDbfs))

            ZStack(alignment: .bottom) {
                trackBackground

                // Signal-green at quiet (good headroom), violet mid,
                // red at the clipping danger zone (>-3 dBFS).
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.signal,  location: 0.0),
                                .init(color: Color.violet,  location: 0.55),
                                .init(color: Color.red,     location: 1.0),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: trackColumnWidth, height: h * rmsFill)
                    .animation(.linear(duration: 0.05), value: rmsDbfs)

                // Peak tick floats above the RMS body. Decays via the
                // mixer's built-in smoothing on peakDbfs.
                Rectangle()
                    .fill(.primary)
                    .frame(width: trackColumnWidth + 2, height: 1.5)
                    .position(
                        x: geo.size.width / 2,
                        y: max(2, h - h * peakFill)
                    )
                    .opacity(peakDbfs > -100 ? 0.85 : 0)
                    .animation(.linear(duration: 0.05), value: peakDbfs)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(peakReadout)
    }

    // MARK: - Helpers

    /// Empty-track fill. System fill so it follows appearance; one
    /// step stronger under Increase Contrast.
    private var trackBackground: some View {
        Capsule()
            .fill(contrast == .increased ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
            .frame(width: trackColumnWidth)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(weight: .medium, size: 9).swiftUI)
            .tracking(1.6)
            .foregroundStyle(.secondary)
    }

    private var volumeFraction: Double {
        (vm.monitorVolume - volumeMin) / (volumeMax - volumeMin)
    }

    private var volumeReadout: String {
        if !vm.monitorEnabled { return "MUTED" }
        return "\(Int(vm.monitorVolume * 100))%"
    }

    private var peakReadout: String {
        guard peakDbfs > -100 else { return "—" }
        return String(format: "%+.0f dB", peakDbfs)
    }

    /// dBFS (-60…0) → 0…1 fraction. Quiet input still registers
    /// visibly without compressing loud peaks.
    private func normalize(_ dbfs: Float) -> Float {
        let floor: Float = -60
        let ceil: Float = 0
        let clamped = min(max(dbfs, floor), ceil)
        return (clamped - floor) / (ceil - floor)
    }

    private func clamp01(_ v: Double) -> Double {
        min(max(v, 0), 1)
    }

    /// Toggle monitor on/off. Targeted by both the inline button and
    /// the window-level keyboard shortcut.
    func toggleMonitor() {
        vm.monitorEnabled.toggle()
    }
}

// MARK: - Preview

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
