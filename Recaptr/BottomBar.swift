//
//  BottomBar.swift
//  Recaptr
//
//  One glass bar along the bottom: game and mic on the left, record in
//  the middle, time and markers on the right. Click a channel for its
//  level, input and headphone volume.
//

import SwiftUI
import CoreMedia

struct BottomBar: View {
    @EnvironmentObject var vm: MainViewModel
    var onScreenshot: () -> Void
    var onToggleRecord: () -> Void
    var onMark: () -> Void
    /// Shared with the recording pill so the bar morphs into it.
    var glassNamespace: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ChannelChip(channel: .game)
                ChannelChip(channel: .mic)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio")
            .accessibilityIdentifier("audioPill")
            .frame(maxWidth: .infinity, alignment: .leading)

            RecordingControlsPill(
                isRecording: vm.isRecording,
                canRecord: vm.isPreviewing || vm.selectedMainSource != nil,
                onScreenshot: onScreenshot,
                onToggleRecord: onToggleRecord,
                onMark: onMark,
                standalone: false,
                recordKey: vm.hotKeyLabel(for: .toggleRecording),
                markerKey: vm.hotKeyLabel(for: .dropMarker)
            )

            BarStatus(clock: vm.clock, markerCount: vm.markers.count, isRecording: vm.isRecording)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Same inset all round so the chips' capsules sit concentric in the bar's.
        .padding(6)
        .frame(maxWidth: 860)
        .recaptrGlass(in: Capsule(),
                      tint: vm.isRecording ? Color.red.opacity(0.12) : nil)
        .animation(Motion.pick(Motion.fade, reduceMotion: reduceMotion), value: vm.isRecording)
        .recaptrGlassID(BottomBar.glassID, in: glassNamespace)
    }

    static let glassID = "bottomGlass"
}

// MARK: - Channel

enum BarChannel {
    case game, mic

    var index: Int { self == .game ? 0 : 1 }
}

/// Icon and meter (click for the popover), then the headphones toggle.
private struct ChannelChip: View {
    let channel: BarChannel
    @EnvironmentObject var vm: MainViewModel
    @State private var showsPopover = false
    @State private var isHovering = false
    @Environment(\.chromeVisible) private var chromeVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isScreen: Bool { vm.selectedMainSource.map { $0.kind != .camera } ?? false }
    private var isLive: Bool { channel == .game ? vm.selectedMainSource != nil : vm.hasMic }

    var body: some View {
        HStack(spacing: 8) {
            Button { showsPopover.toggle() } label: {
                Image(systemName: icon)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isLive ? .primary : .secondary)
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(channel == .game ? "Game audio: level and headphones" : "Mic: input, level and headphones")
            .accessibilityLabel(channel == .game ? "Game audio settings" : "Mic settings")
            .accessibilityIdentifier(channel == .game ? "gameChannel" : "micChannel")
            .popover(isPresented: $showsPopover, arrowEdge: .top) {
                ChannelPopover(channel: channel).environmentObject(vm)
            }

            // Separate from the button so the meter keeps its own identifier.
            LevelMeter(levels: levels, active: chromeVisible && isLive, vertical: false,
                       thickness: 6, label: channel == .game ? "Game level" : "Mic level")
                .frame(width: 56, height: 6)
                .opacity(isLive ? 1 : 0.4)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture { showsPopover.toggle() }
                .accessibilityIdentifier(channel == .game ? "sourceLevel" : (vm.hasMic ? "micLevel" : "micLevelOff"))

            monitorToggle
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .background(
            Capsule()
                .fill(isHovering || showsPopover ? Color.primary.opacity(0.08) : .clear)
        )
        .onHover { isHovering = $0 }
        .animation(Motion.pick(Motion.fade, reduceMotion: reduceMotion), value: isHovering)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: monitorOn)
    }

    private var icon: String {
        switch channel {
        case .game: return isScreen ? "speaker.wave.2" : "gamecontroller"
        case .mic: return vm.hasMic ? "mic" : "mic.slash"
        }
    }

    private func levels() -> (rms: Float, peak: Float)? {
        channel == .game ? vm.sourceLevels() : vm.micLevels()
    }

    private var monitorOn: Bool {
        channel == .game ? vm.gameMonitorEnabled : vm.micMonitorEnabled
    }

    /// Screen captures don't monitor game audio: it already plays through the speakers.
    private var canMonitor: Bool {
        channel == .game ? vm.selectedMainSource?.kind == .camera : vm.hasMic
    }

    /// The channel ⌘K controls keeps the 1.0 identifier.
    private var toggleID: String {
        let legacy = vm.monitorChannelIndex ?? 0
        return channel.index == legacy ? "monitorToggle" : (channel == .game ? "gameMonitorToggle" : "micMonitorToggle")
    }

    private var monitorToggle: some View {
        Button {
            if channel == .game { vm.gameMonitorEnabled.toggle() } else { vm.micMonitorEnabled.toggle() }
        } label: {
            Image(systemName: monitorOn ? "headphones" : "headphones.slash")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(monitorOn ? AnyShapeStyle(Color.signal) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(monitorOn ? Color.signal.opacity(0.18) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canMonitor)
        .help(monitorHelp)
        .accessibilityLabel(channel == .game ? "Monitor game audio" : "Monitor mic")
        .accessibilityValue(monitorOn ? "On" : "Muted")
        .accessibilityIdentifier(toggleID)
    }

    private var monitorHelp: String {
        switch channel {
        case .game:
            if isScreen { return "System audio already plays through your speakers." }
            return withKeys(monitorOn ? "Stop listening to game audio" : "Listen to game audio")
        case .mic:
            if !vm.hasMic { return "Choose a mic to listen to it" }
            return withKeys(monitorOn ? "Stop listening to your mic" : "Listen to your mic")
        }
    }

    /// ⌘K for the channel it controls, plus any global key.
    private func withKeys(_ text: String) -> String {
        let global = vm.hotKeyLabel(for: channel == .game ? .toggleGameMonitor : .toggleMicMonitor)
        let local = channel.index == (vm.monitorChannelIndex ?? 0) ? "⌘K" : nil
        switch (local, global) {
        case let (l?, g?): return "\(text) (\(l), or \(g) from any app)"
        case let (l?, nil): return "\(text) (\(l))"
        case let (nil, g?): return "\(text) (\(g) from any app)"
        default: return text
        }
    }
}

// MARK: - Popover

/// Input, recorded level, and the shared headphone volume.
private struct ChannelPopover: View {
    let channel: BarChannel
    @EnvironmentObject var vm: MainViewModel

    private var isCamera: Bool { vm.selectedMainSource?.kind == .camera }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(channel == .game ? "Game audio" : "Mic")
                .font(.headline)

            if channel == .game, !isCamera {
                Text("System audio is recorded as it plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Input", selection: channel == .game ? $vm.ch1DeviceID : $vm.ch2DeviceID) {
                    Text("None").tag(String?.none)
                    ForEach(vm.availableAudioSources) { src in
                        Text(src.name).tag(String?.some(src.id))
                    }
                }
                .accessibilityIdentifier(channel == .game ? "barSourceDevicePicker" : "barMicDevicePicker")

                if channel == .game || vm.hasMic {
                    percentSlider("Level", value: channel == .game ? $vm.ch1Gain : $vm.ch2Gain,
                                  id: channel == .game ? "gameLevel" : "micLevelSlider")
                    Text("What's recorded. Listening follows it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            percentSlider("Headphones", value: $vm.headphoneVolume, id: "monitorVolume")
            Text("Only what you hear. Never the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func percentSlider(_ title: String, value: Binding<Double>, id: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Slider(value: value, in: 0...1.5) { Text(title) }
                    .labelsHidden()
                    .accessibilityIdentifier(id)
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - Status

/// Elapsed time, size and markers while recording; time left on the
/// drive otherwise. Observes only the clock so its tick doesn't redraw
/// the window.
private struct BarStatus: View {
    @ObservedObject var clock: RecordingClock
    let markerCount: Int
    let isRecording: Bool

    @EnvironmentObject var vm: MainViewModel
    @State private var diskTime: DiskTime?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(clock.anchored ? 1.0 : 0.45)
                Text(clock.formattedElapsed)
                    .font(BrandFont.mono(weight: .semibold, size: 15).swiftUI)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(reduceMotion ? nil : Motion.snappy, value: clock.formattedElapsed)
                if clock.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: clock.bytes, countStyle: .file))
                        .font(BrandFont.mono(weight: .regular, size: 11).swiftUI)
                        .foregroundStyle(.secondary)
                }
            } else if let diskTime {
                Text(diskTime.label)
                    .font(BrandFont.body(weight: .medium, size: 13).swiftUI)
                    .foregroundStyle(diskTime.level.color)
                    .help("Recording time left on the save drive at the current preset")
            }
            if markerCount > 0, isRecording {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.signal)
                    Text("\(markerCount)")
                        .font(BrandFont.mono(weight: .medium, size: 12).swiftUI)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
        }
        .animation(Motion.pick(Motion.pop, reduceMotion: reduceMotion), value: markerCount)
        .padding(.trailing, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("barStatus")
        .task(id: isRecording) {
            // Free space changes slowly; every 30 s is plenty.
            while !Task.isCancelled {
                diskTime = vm.diskTimeLeft()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: vm.videoQuality) { _, _ in diskTime = vm.diskTimeLeft() }
        .onChange(of: vm.activeCaptureSize?.width) { _, _ in diskTime = vm.diskTimeLeft() }
    }
}
