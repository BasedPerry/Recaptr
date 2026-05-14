//
//  VolumeBar.swift
//  Recaptr
//
//  Vertical volume control modeled on the Apple TV system Volume
//  HUD: dark translucent capsule, no separate thumb (the fill
//  terminus is the indicator), drag-anywhere gesture target,
//  mixer button on top + mute button on bottom.
//
//  Currently unused — superseded by `AudioModule`, kept here for
//  reference. Safe to delete once the new pill is locked in.
//

import SwiftUI

struct VolumeBar: View {
    @Binding var volume: Double          // 0...1
    @Binding var isMuted: Bool
    @Binding var isMixerOpen: Bool
    var onOpenMixer: () -> Void
    var onToggleMute: () -> Void

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

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let trackWidth: CGFloat = 6
            let filled = max(0, min(1, volume))

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.beige.opacity(0.08))
                    .frame(width: trackWidth)

                // Fill grows from the bottom. Active state uses the
                // brand signal gradient; muted collapses to a flat
                // dim tone matching the system mute HUD convention.
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
                        color: isMuted ? .clear : Color.signal.opacity(0.45),
                        radius: 6,
                        y: -2
                    )
                    .animation(.linear(duration: 0.08), value: volume)

                // Wider invisible hit target so drag works anywhere
                // along the bar, not just on the visible track.
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

#Preview("Volume Bar") {
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
