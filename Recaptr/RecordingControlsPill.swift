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
//  The pill is the only glass layer. Side buttons are borderless on
//  purpose: glass buttons inside a glass pill would stack glass on
//  glass, which Apple's Liquid Glass guidance says to avoid.
//

import SwiftUI

struct RecordingControlsPill: View {
    let isRecording: Bool
    let canRecord: Bool
    var onScreenshot: () -> Void
    var onToggleRecord: () -> Void
    var onMark: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 28) {
            sideButton(
                icon: "camera.viewfinder",
                label: "Screenshot",
                enabled: true,
                id: "screenshotButton",
                action: onScreenshot
            )
            recordButton
            sideButton(
                icon: "bookmark.fill",
                label: "Clip Marker",
                enabled: isRecording,
                disabledHelp: "Clip markers are available while recording",
                id: "markerButton",
                action: onMark
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        // Neutral glass so the record button stays the loudest element;
        // a faint red tint while recording says "live" from across the
        // room.
        .recaptrGlass(tint: isRecording ? Color.red.opacity(0.12) : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isRecording)
    }

    // MARK: Side button (Screenshot / Marker)

    @ViewBuilder
    private func sideButton(
        icon: String,
        label: String,
        enabled: Bool,
        disabledHelp: String? = nil,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Disabled is .secondary, not fainter: over dark video
            // anything dimmer looked like a rendering glitch.
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? label : (disabledHelp ?? label))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
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
                            .stroke(.primary, lineWidth: 2.5)
                    }
                }
                .frame(width: 60, height: 60)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isRecording)

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
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.35),
                           value: isRecording)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canRecord && !isRecording)
        .help(isRecording ? "Stop Recording" : "Start Recording")
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
        .accessibilityIdentifier("recordButton")
    }
}

// MARK: - Preview

#Preview("Recording Controls, Dark") {
    ChromePreviewStage { RecordingControlsPreview() }
        .frame(width: 1200, height: 300)
        .preferredColorScheme(.dark)
}

#Preview("Recording Controls, Light") {
    ChromePreviewStage { RecordingControlsPreview() }
        .frame(width: 1200, height: 300)
        .preferredColorScheme(.light)
}

private struct RecordingControlsPreview: View {
    @State private var idle = false
    @State private var recording = true

    var body: some View {
        VStack(spacing: 24) {
            RecordingControlsPill(isRecording: idle, canRecord: true,
                                  onScreenshot: { }, onToggleRecord: { idle.toggle() },
                                  onMark: { })
            RecordingControlsPill(isRecording: recording, canRecord: true,
                                  onScreenshot: { }, onToggleRecord: { recording.toggle() },
                                  onMark: { })
        }
    }
}
