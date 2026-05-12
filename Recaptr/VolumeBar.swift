//
//  VolumeBar.swift
//  Recaptr
//
//  Phase 6 — Apple-native vertical volume control modeled on the
//  Apple TV system Volume HUD.
//
//  Apple TV's volume HUD on tvOS:
//    - Vertical capsule, dark translucent background
//    - No separate thumb; the fill terminus IS the indicator
//    - Smooth rounded fill in the system tint
//    - Subtle plus / minus or speaker glyphs at the ends
//    - Drag anywhere on the bar to set, not just on a thumb
//    - "Liquid Glass" surface (or NSVisualEffectView fallback)
//
//  Recaptr's adaptation:
//    - Top icon: `slider.vertical.3` opens the full mixer popover
//      (we keep this semantic instead of Apple TV's plus button —
//      Recaptr's bar is the always-visible master volume, the mixer
//      is the per-source detail view).
//    - Bottom icon: `speaker.wave.2.fill` / `speaker.slash.fill`
//      toggles mute. Apple TV uses speaker icons in its mute HUD,
//      so this stays inside the design language.
//    - Tap-and-drag anywhere on the bar to set the volume (the
//      bar IS the gesture target, no separate thumb required).
//    - Subtle "press" depth on drag, matching Apple TV's stretch.
//

import SwiftUI

struct VolumeBar: View {
    @Binding var volume: Double          // 0...1
    @Binding var isMuted: Bool
    @Binding var isMixerOpen: Bool
    var onOpenMixer: () -> Void
    var onToggleMute: () -> Void

    /// Width of the bar at rest. Apple TV's HUD bar is narrower
    /// than typical macOS sliders — feels precise rather than chunky.
    private let baseWidth: CGFloat = 36
    private let height: CGFloat = 240

    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 10) {
            mixerButton
            track
            muteButton
        }
        .frame(width: baseWidth + (isDragging ? 4 : 0))
        .frame(height: height)
        .padding(.vertical, 8)
        // True Liquid Glass — see Glass.swift. v1 stacked .thinMaterial
        // under a 0.55 surface fill, which read as a solid graphite
        // column. Now it's actual translucent glass with a violet
        // hero-tint at the top — the brand color still shows up at a
        // glance, but the preview shows through the bar.
        .brandGlassCapsule(topTint: .violet)
        .animation(.spring(duration: 0.22, bounce: 0.18), value: isDragging)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100)) percent" + (isMuted ? ", muted" : ""))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: volume = min(1, volume + 0.05)
            case .decrement: volume = max(0, volume - 0.05)
            @unknown default: break
            }
        }
    }

    // MARK: Mixer button (top)

    private var mixerButton: some View {
        Button(action: onOpenMixer) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.recaptrTextSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(isMixerOpen ? Color.recaptrAccentMuted : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isMixerOpen ? "Mixer open" : "Open mixer")
    }

    // MARK: Track — the Apple-TV-style fill area

    private var track: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let trackWidth: CGFloat = 6
            let filled = max(0, min(1, volume))

            ZStack(alignment: .bottom) {
                // Resting track — subtle inset, no hard border. The
                // capsule fill provides "the rail" and the bar itself
                // provides depth.
                Capsule()
                    .fill(Color.beige.opacity(0.08))
                    .frame(width: trackWidth)

                // Fill — grows from bottom, capsule-rounded. Uses
                // a vertical slice of the brand signal gradient
                // (restore → violet → signal) when active, so the
                // bar visually "lights up" as it rises. Muted state
                // collapses to a single dim tone — matches Apple's
                // HUD behavior when the system is muted.
                Capsule()
                    .fill(
                        isMuted
                        ? AnyShapeStyle(Color.recaptrTextDim)
                        : AnyShapeStyle(LinearGradient(
                            stops: [
                                .init(color: Color.restore, location: 0.0),
                                .init(color: Color.violet,  location: 0.6),
                                .init(color: Color.signal,  location: 1.0),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        ))
                    )
                    .frame(width: trackWidth, height: h * CGFloat(filled))
                    .shadow(
                        // Subtle brand-colored glow above the fill
                        // terminus, like Apple TV's HUD where the
                        // top of the fill emits soft light. Drops
                        // off cleanly when muted.
                        color: isMuted ? .clear : Color.signal.opacity(0.45),
                        radius: 6,
                        y: -2
                    )
                    .animation(.linear(duration: 0.08), value: volume)

                // Invisible wider hit target — Apple TV lets you
                // drag anywhere along the bar, not just on the
                // visible track. Add a few points of slack on
                // either side.
                Color.clear
                    .frame(width: max(20, trackWidth + 14))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let new = 1 - (value.location.y / h)
                                volume = Double(max(0, min(1, new)))
                                if !isDragging { isDragging = true }
                            }
                            .onEnded { _ in
                                isDragging = false
                            }
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Mute button (bottom)

    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isMuted ? Color.recaptrWarning : Color.recaptrTextSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute" : "Mute")
    }
}

// MARK: - Preview

#Preview("Volume Bar — Apple TV style") {
    PreviewWrapper()
        .frame(width: 420, height: 380)
        .background(Color.recaptrBackground)
}

private struct PreviewWrapper: View {
    @State private var volA: Double = 1.0
    @State private var volB: Double = 0.6
    @State private var volC: Double = 0.6

    @State private var muteA = false
    @State private var muteB = false
    @State private var muteC = true

    @State private var mixerA = false
    @State private var mixerB = true
    @State private var mixerC = false

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            stateColumn("100%") {
                VolumeBar(
                    volume: $volA, isMuted: $muteA, isMixerOpen: $mixerA,
                    onOpenMixer: { mixerA.toggle() },
                    onToggleMute: { muteA.toggle() }
                )
            }
            stateColumn("60% · MIXER OPEN") {
                VolumeBar(
                    volume: $volB, isMuted: $muteB, isMixerOpen: $mixerB,
                    onOpenMixer: { mixerB.toggle() },
                    onToggleMute: { muteB.toggle() }
                )
            }
            stateColumn("MUTED") {
                VolumeBar(
                    volume: $volC, isMuted: $muteC, isMixerOpen: $mixerC,
                    onOpenMixer: { mixerC.toggle() },
                    onToggleMute: { muteC.toggle() }
                )
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func stateColumn<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: 12) {
            Text(label)
                .font(BrandFont.mono(weight: .regular, size: 10).swiftUI)
                .tracking(1.6)
                .foregroundStyle(Color.recaptrAccent)
            content()
        }
    }
}
