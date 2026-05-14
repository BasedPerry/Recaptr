//
//  RecordingControlsPill.swift
//  Recaptr
//
//  Three-button capture controls pill following the Apple-native
//  record-button convention (iOS Camera, Voice Memos): red circle
//  that morphs to a red rounded square while recording, with an
//  outline ring framing it.
//
//  Layout: [Screenshot]   [● Record/Stop]   [Marker]
//
//  Side buttons are compact icon buttons; the center record button
//  is intentionally larger and louder as the primary action. The
//  Screenshot, Record, and Marker actions are wired as closures so
//  the parent view owns their behavior.
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
        // Neutral glass background — keeps the record button as the
        // loudest element rather than competing with the source pill.
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

    // MARK: Record button

    private var recordButton: some View {
        Button(action: onToggleRecord) {
            ZStack {
                // Outer ring. While recording, fills with the brand
                // gradient so the active state visually echoes the
                // app icon. Idle stays neutral.
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

                // Inner indicator morphs between circle (idle) and
                // rounded square (recording).
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
                    onScreenshot: { },
                    onToggleRecord: { recA.toggle() },
                    onMark: { }
                )
            }
            stateBlock("RECORDING IN PROGRESS") {
                RecordingControlsPill(
                    isRecording: recB,
                    canRecord: true,
                    onScreenshot: { },
                    onToggleRecord: { recB.toggle() },
                    onMark: { }
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
