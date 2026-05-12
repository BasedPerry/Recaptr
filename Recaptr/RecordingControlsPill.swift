//
//  RecordingControlsPill.swift
//  Recaptr
//
//  Phase 6 — three-button capture controls pill, modeled on
//  Apple-native record-button conventions (iOS Camera app +
//  Voice Memos pattern: red circle that morphs to red rounded
//  square when recording, white outline ring around it).
//
//  Layout: [Screenshot]   [● Record/Stop]   [Marker]
//
//  Brand-tinted glass capsule background to match the source
//  pill + volume bar. Side buttons are compact icon buttons;
//  the center record button is intentionally larger and louder
//  — it's the primary CTA.
//
//  Screenshot and Marker actions are wired as closure props so
//  the parent view (ContentViewNext) controls behavior. v1 stubs
//  them (print to console); Phase 6 polish implements them.
//

import SwiftUI

struct RecordingControlsPill: View {
    let isRecording: Bool
    let canRecord: Bool
    var onScreenshot: () -> Void
    var onToggleRecord: () -> Void
    var onMark: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            sideButton(
                icon: "camera.viewfinder",
                label: "Screenshot",
                enabled: true,
                action: onScreenshot
            )
            recordButton
            sideButton(
                icon: "bookmark.fill",
                label: "Clip Marker",
                enabled: isRecording,
                action: onMark
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        // Phase 6.2 — neutral glass. v2 of this pill had a violet
        // hero-tint at top, which made it compete with the source
        // pill for attention. The pill is now visually quiet so the
        // record button (the actual CTA) is the loudest element on
        // screen.
        .brandGlassCapsule(topTint: nil)
    }

    // MARK: Side button (Screenshot / Marker)

    @ViewBuilder
    private func sideButton(
        icon: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(enabled ? Color.recaptrTextSecondary : Color.recaptrTextDim)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
    }

    // MARK: Record button (center, primary CTA)

    private var recordButton: some View {
        Button(action: onToggleRecord) {
            ZStack {
                // Outer ring — Apple's recording-button signature.
                // Phase 6.2: bumped from 48→60, stroke 2→2.5.
                // Phase 6.3: while recording, the ring fills with the
                // app-icon signal gradient (restore→violet→signal at
                // 135°) so the active state visually echoes the icon.
                // Idle stays neutral so red disk = "ready", gradient
                // ring = "live".
                Group {
                    if isRecording {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.restore, .violet, .signal],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2.5
                            )
                    } else {
                        Circle()
                            .stroke(
                                Color.recaptrTextSecondary.opacity(0.55),
                                lineWidth: 2.5
                            )
                    }
                }
                .frame(width: 60, height: 60)
                .animation(.easeInOut(duration: 0.25), value: isRecording)

                // Inner indicator — morphs between circle (idle)
                // and rounded square (recording). Phase 6.2: idle disk
                // bumped 36→44, recording square 18→22. Same Apple
                // pattern, just louder.
                Group {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.red)
                            .frame(width: 22, height: 22)
                    } else {
                        Circle()
                            .fill(canRecord ? Color.red : Color.red.opacity(0.45))
                            .frame(width: 44, height: 44)
                    }
                }
                .animation(.spring(duration: 0.28, bounce: 0.35), value: isRecording)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canRecord && !isRecording)
        .help(isRecording ? "Stop Recording" : "Start Recording")
    }
}

// MARK: - Preview

#Preview("Recording Controls — idle / recording") {
    PreviewWrapper()
        .frame(width: 420, height: 280)
        .background(Color.recaptrBackground)
}

private struct PreviewWrapper: View {
    @State private var recA = false
    @State private var recB = true

    var body: some View {
        VStack(spacing: 32) {
            stateBlock("IDLE · CAN RECORD") {
                RecordingControlsPill(
                    isRecording: recA,
                    canRecord: true,
                    onScreenshot: { print("screenshot A") },
                    onToggleRecord: { recA.toggle() },
                    onMark: { print("mark A") }
                )
            }
            stateBlock("RECORDING IN PROGRESS") {
                RecordingControlsPill(
                    isRecording: recB,
                    canRecord: true,
                    onScreenshot: { print("screenshot B") },
                    onToggleRecord: { recB.toggle() },
                    onMark: { print("mark B") }
                )
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func stateBlock<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(BrandFont.mono(weight: .regular, size: 10).swiftUI)
                .tracking(1.6)
                .foregroundStyle(Color.recaptrAccent)
            content()
        }
    }
}
