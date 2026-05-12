//
//  AudioModule.swift
//  Recaptr
//
//  Phase 6.3.2 — replaces VolumeBar on the right edge of the QuickTime
//  chrome. Two dynamic concerns + one read-only telemetry:
//
//    1. MONITOR toggle  — am I hearing the input in my headphones
//                         (constantly toggled mid-session, especially
//                         when switching screens / answering things)
//    2. MONITOR volume  — how loud the monitor is (varies per game /
//                         per conversation — RDR2 quieter, Marathon
//                         100%, podcast guest somewhere in between)
//    3. INPUT VU        — visual "is my mic hot" — read-only, stays
//                         visible regardless of monitor state so you
//                         can glance and confirm mic is being captured
//                         even with monitor muted
//
//  Why monitor here, gain in Settings. For a gameplay/streaming
//  creator, mic gain is set once per session and forgotten (same
//  mic, same room, same voice). Monitor volume changes constantly
//  with the game audio level. The pill is the always-visible knob
//  for the dynamic concern; gain lives behind the gear because it's
//  a set-and-forget calibration.
//
//  Layout (vertical capsule, ~64pt wide × ~280pt tall):
//    ┌───────────┐
//    │   AUDIO   │
//    │           │
//    │    🎧     │   ← monitor toggle (click or ⌘K to mute)
//    │           │
//    │   ▮ ▮     │   ← left col = monitor volume (draggable)
//    │   ▮ ▮     │     right col = VU meter (read-only)
//    │   ●▮▮     │
//    │   ▮ ▮     │
//    │           │
//    │   82%     │   ← monitor volume readout
//    │  -18 dB   │   ← live peak readout (always visible)
//    └───────────┘
//
//  Keyboard shortcut. The monitor toggle is wired to `toggleMonitor()`
//  — Phase 6.4 will bind this to ⌘K (or whatever the eventual shortcut
//  is) at the window level so monitor mute works from anywhere in
//  the app.
//
//  VU update rate. AudioMixer computes rms+peak per buffer (~21ms
//  cadence). The mixerStats @Published updates at 1Hz which is too
//  slow for a meter. This view runs its own 30Hz Timer that calls
//  vm.currentAudioLevels() and stores the result in local @State,
//  so the meter feels continuous without bumping global re-render
//  cost.
//

import SwiftUI
import Combine    // for Timer.publish(...).autoconnect()

struct AudioModule: View {

    @EnvironmentObject var vm: MainViewModel

    // ── Live VU state, updated by .onReceive of a 30Hz timer ────────
    @State private var rmsDbfs: Float = -120
    @State private var peakDbfs: Float = -120

    // ── Drag-stretch state (matches the v1 VolumeBar feel) ──────────
    @State private var isDraggingVolume: Bool = false

    // ── 30Hz timer publisher for VU updates ─────────────────────────
    // Auto-connected, runs while the view is mounted, fires on main.
    private let vuTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    // ── Dimensions ──────────────────────────────────────────────────
    private let baseWidth: CGFloat = 64
    private let totalHeight: CGFloat = 280
    private let trackHeight: CGFloat = 160
    private let trackColumnWidth: CGFloat = 8     // volume + VU column widths

    /// Monitor volume range — matches MainViewModel.monitorVolume (0…1.5).
    private let volumeMin: Double = 0
    private let volumeMax: Double = 1.5

    var body: some View {
        audioBody
        .frame(width: baseWidth + (isDraggingVolume ? 4 : 0))
        .frame(height: totalHeight)
        .padding(.vertical, 12)
        .brandGlassCapsule(topTint: .violet)
        .animation(.spring(duration: 0.22, bounce: 0.18), value: isDraggingVolume)
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

    // MARK: - Body: monitor toggle + monitor volume + VU
    //
    // Stack: AUDIO label → headphone toggle → parallel tracks
    // (monitor volume on left, VU on right) → percentage + peak
    // readouts. Headphone toggle is the always-reachable mute, VU
    // is read-only and stays visible regardless of monitor state.

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
                    .foregroundStyle(vm.monitorEnabled ? Color.recaptrTextPrimary : Color.recaptrTextMuted)
                Text(peakReadout)
                    .font(BrandFont.mono(weight: .regular, size: 9).swiftUI)
                    .foregroundStyle(Color.recaptrTextMuted)
            }
        }
        .padding(.horizontal, 8)
    }

    // Headphone toggle. Click = mute / unmute monitor. Designed to
    // bind to a window-level keyboard shortcut (Phase 6.4 — e.g. ⌘K)
    // so the same toggle works from anywhere in the app, including
    // when the chrome is faded out.
    private var monitorToggle: some View {
        Button(action: toggleMonitor) {
            Image(systemName: vm.monitorEnabled ? "headphones" : "headphones.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(vm.monitorEnabled ? Color.signal : Color.recaptrTextSecondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(vm.monitorEnabled ? Color.signal.opacity(0.18) : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(vm.monitorEnabled ? "Mute monitor" : "Unmute monitor")
    }

    private var volumeTrack: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let fill = CGFloat(clamp01(volumeFraction))
            // When monitor is muted, the volume column visually dims
            // but stays draggable — adjusting it pre-positions the
            // volume for when monitor comes back on.
            let isLive = vm.monitorEnabled

            ZStack(alignment: .bottom) {
                // Resting track
                Capsule()
                    .fill(Color.beige.opacity(0.10))
                    .frame(width: trackColumnWidth)

                // Active fill — restore→violet→signal bottom-up.
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

                // Thumb dot at the fill terminus
                Circle()
                    .fill(Color.beigeBright)
                    .frame(width: 10, height: 10)
                    .opacity(isLive ? 1.0 : 0.5)
                    .position(
                        x: geo.size.width / 2,
                        y: max(5, h - h * fill)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .allowsHitTesting(false)

                // Hit target — drag anywhere in the column to set value
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
    }

    private var vuTrack: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let rmsFill = CGFloat(normalize(rmsDbfs))
            let peakFill = CGFloat(normalize(peakDbfs))

            ZStack(alignment: .bottom) {
                // Resting VU rail
                Capsule()
                    .fill(Color.beige.opacity(0.08))
                    .frame(width: trackColumnWidth)

                // RMS fill — main "loudness" body. Different gradient
                // from gain so it reads as a different concept:
                // signal-green at quiet (good headroom), violet mid,
                // red at clipping danger zone (>-3 dBFS).
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

                // Peak tick — thin horizontal line above the RMS fill,
                // marks the most recent peak. Decays via the mixer's
                // built-in smoothing on peakDbfs.
                Rectangle()
                    .fill(Color.beigeBright)
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
    }

    // MARK: - Bits and bobs

    private var separator: some View {
        // Phase 6.3.1: separator preserved for potential reuse; no
        // longer drawn since the monitor section was removed.
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(weight: .medium, size: 9).swiftUI)
            .tracking(1.6)
            .foregroundStyle(Color.recaptrAccent)
    }

    // MARK: - Readouts and conversions

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

    /// dBFS (-60..0) → 0..1 fraction with mild log curve so quiet
    /// sounds register visibly without compressing loud peaks.
    /// Matches the existing VUMeterView convention in ContentView.
    private func normalize(_ dbfs: Float) -> Float {
        let floor: Float = -60
        let ceil: Float = 0
        let clamped = min(max(dbfs, floor), ceil)
        return (clamped - floor) / (ceil - floor)
    }

    private func clamp01(_ v: Double) -> Double {
        min(max(v, 0), 1)
    }

    // MARK: - Monitor toggle (also targeted by future keyboard shortcut)

    /// Toggle monitor on/off. Window-level keyboard shortcut in
    /// Phase 6.4 will hit this same method via a hidden Button or a
    /// dedicated AppCommands binding.
    func toggleMonitor() {
        vm.monitorEnabled.toggle()
    }
}

// MARK: - Preview

#Preview("Audio Module — idle + active states") {
    PreviewWrapper()
        .frame(width: 460, height: 420)
        .background(Color.recaptrBackground)
}

private struct PreviewWrapper: View {
    @StateObject private var vm = MainViewModel()

    var body: some View {
        HStack(spacing: 40) {
            VStack {
                Text("CURRENT STATE")
                    .font(BrandFont.mono(weight: .regular, size: 10).swiftUI)
                    .tracking(1.6)
                    .foregroundStyle(Color.recaptrAccent)
                AudioModule()
                    .environmentObject(vm)
            }
        }
        .padding(30)
    }
}
