//
//  RecordingControlsPill.swift
//  Recaptr
//
//  Screenshot, record, and marker buttons. Side buttons are plain because
//  glass buttons inside a glass pill would stack glass on glass.
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
                label: "Clip Marker (⌘B, or ⌃⌥⌘B from any app)",
                enabled: isRecording,
                disabledHelp: "Clip markers are available while recording",
                id: "markerButton",
                action: onMark
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .recaptrGlass(tint: isRecording ? Color.red.opacity(0.12) : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isRecording)
    }

    // MARK: Side button

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
            // Anything dimmer than .secondary looks broken over dark video.
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
                // Brand gradient ring while recording.
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

// ChromePreviewStage is debug-only.
#if DEBUG

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
#endif
