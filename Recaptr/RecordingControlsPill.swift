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
    /// False inside the bottom bar, which brings its own glass.
    var standalone = true
    /// Current global keys, shown in the tooltips.
    var recordKey: String? = nil
    var markerKey: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if standalone {
            buttons
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .recaptrGlass(tint: isRecording ? Color.red.opacity(0.12) : nil)
                .animation(Motion.pick(Motion.fade, reduceMotion: reduceMotion), value: isRecording)
        } else {
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: standalone ? 28 : 18) {
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
                help: Self.shortcutHelp("Clip Marker", key: "⌘B", global: markerKey),
                enabled: isRecording,
                disabledHelp: "Clip markers are available while recording",
                id: "markerButton",
                action: onMark
            )
        }
    }

    /// "Clip Marker (⌘B, or ⌃⌥⌘B from any app)".
    static func shortcutHelp(_ title: String, key: String, global: String?) -> String {
        "\(title) (\(key)" + (global.map { ", or \($0) from any app" } ?? "") + ")"
    }

    // MARK: Side button

    @ViewBuilder
    private func sideButton(
        icon: String,
        label: String,
        help: String? = nil,
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
        .help(enabled ? (help ?? label) : (disabledHelp ?? label))
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
                .animation(Motion.pick(Motion.fade, reduceMotion: reduceMotion), value: isRecording)

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
                .animation(Motion.pick(Motion.pop, reduceMotion: reduceMotion),
                           value: isRecording)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canRecord && !isRecording)
        .help(Self.shortcutHelp(isRecording ? "Stop Recording" : "Start Recording",
                                key: "⌘R", global: recordKey))
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
