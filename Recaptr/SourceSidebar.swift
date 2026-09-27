//
//  SourceSidebar.swift
//  Recaptr
//
//  Left sidebar: the expanded form of the floating source pill. When
//  it's open the pill steps aside; when it's closed (the default) the
//  preview is the whole window, QuickTime style.
//
//  Top: the Window / Screen / Camera switcher (the same control as the
//  pill). Middle: that type's sources; click to switch.
//  Bottom: tuning for the selected method (camera resolution, noise
//  reduction, source audio; instant replay for screens and windows)
//  plus the commentary mic, which applies to every method.
//
//  App-wide settings (save folder, encoding, permissions) stay in the
//  Settings window.
//

import SwiftUI
import CoreMedia

struct SourceSidebar: View {
    @EnvironmentObject var vm: MainViewModel
    @Binding var isVisible: Bool

    private var selectedID: Binding<String?> {
        Binding(
            get: { vm.selectedMainSource?.id },
            set: { id in
                guard let id, let match = vm.catalog.videoSources.first(where: { $0.id == id }) else { return }
                vm.selectedMainSource = match
            }
        )
    }

    /// Type shown in the sidebar. Follows the selected source; set it
    /// to switch type (picks that type's first source, as the pill
    /// does).
    @State private var mode: SourceMode = .camera

    var body: some View {
        // Switcher on top, then one grouped, scrolling form: that
        // type's sources, then that type's tuning. (A separate list
        // and tuning area competed for height and pushed the tuning
        // off the bottom of the window.)
        VStack(spacing: 0) {
            SourceModeSegments(activeMode: modeBinding, compact: true)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            Form {
                Section {
                    sourceRows
                } header: {
                    Label("Source", systemImage: mode.systemImage)
                }
                TuningSections()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .controlSize(.small)
            .accessibilityIdentifier("sourceSidebar")
        }
        .toolbar(removing: .sidebarToggle)
        .onAppear { syncMode() }
        .onChange(of: vm.selectedMainSource) { _, _ in syncMode() }
    }

    private var modeBinding: Binding<SourceMode> {
        Binding(
            get: { mode },
            set: { newMode in
                mode = newMode
                if newMode != .camera { vm.screenModeSelected() }
                vm.selectedMainSource = vm.catalog.videoSources.first { $0.kind == newMode.sourceKind }
            }
        )
    }

    private func syncMode() {
        if let kind = vm.selectedMainSource?.kind { mode = SourceMode(kind) }
    }

    @ViewBuilder
    private var sourceRows: some View {
        let kind = mode.sourceKind
        let sources = vm.catalog.videoSources.filter { $0.kind == kind }
        if kind != .camera && !vm.screenCapturePermissionGranted {
            Button("Allow Screen Recording…") { vm.screenModeSelected() }
        } else if sources.isEmpty {
            Text(kind == .camera ? "No cameras connected" : kind == .screenDisplay ? "No displays" : "No windows open")
                .foregroundStyle(.secondary)
        } else if kind == .screenWindow {
            // Windows can be many: a menu keeps the sidebar compact.
            Picker("Window", selection: selectedID) {
                ForEach(sources) { Text(Self.displayName($0)).tag(String?.some($0.id)) }
            }
            .accessibilityIdentifier("windowPicker")
        } else {
            ForEach(sources) { source in
                sourceRow(source)
            }
        }
    }

    private func sourceRow(_ source: VideoSource) -> some View {
        let isSelected = vm.selectedMainSource?.id == source.id
        return Button {
            vm.selectedMainSource = source
        } label: {
            HStack {
                Label(Self.displayName(source), systemImage: mode.systemImage)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Catalog names carry a kind prefix ("Camera — Elgato 4K X")
    /// that the section header already says.
    static func displayName(_ source: VideoSource) -> String {
        for prefix in ["Camera — ", "Screen — ", "Window — "] where source.name.hasPrefix(prefix) {
            return String(source.name.dropFirst(prefix.count))
        }
        return source.name
    }
}

// MARK: - Tuning

/// Per-type tuning sections, grouped like System Settings: Video
/// (camera), Audio (every type), Instant Replay (screen and window).
/// Only the groups that apply are shown. Lives inside the sidebar's
/// form, below the Source section.
private struct TuningSections: View {
    @EnvironmentObject var vm: MainViewModel

    private var kind: VideoSource.Kind { vm.selectedMainSource?.kind ?? .camera }
    private var isCamera: Bool { kind == .camera }

    var body: some View {
        Group {
            if isCamera {
                Section {
                    Picker("Resolution", selection: $vm.captureResolution) {
                        ForEach(CaptureResolution.allCases) { Text($0.shortLabel).tag($0) }
                    }
                    .onChange(of: vm.captureResolution) { _, _ in restartCameraPreview() }
                    // Only webcams and Continuity Camera support it;
                    // a capture card would just show a dead switch.
                    if vm.lowLightNoiseReductionSupported {
                        Toggle("Low-light cleanup", isOn: $vm.lowLightNoiseReduction)
                            .onChange(of: vm.lowLightNoiseReduction) { _, _ in restartCameraPreview() }
                    }
                } header: {
                    Label("Video", systemImage: "video")
                } footer: {
                    Text(videoFooter)
                }
            }

            Section {
                if isCamera {
                    // "Input", not "Source": the section above is the
                    // video source, and the two read as the same thing.
                    devicePicker("Input", selection: $vm.ch1DeviceID, id: "sourceDevicePicker")
                    gainRow($vm.ch1Gain)
                } else {
                    LabeledContent("Input", value: "System audio")
                }
                LevelRow(levels: { vm.sourceLevels() })

                devicePicker("Mic", selection: $vm.ch2DeviceID, id: "micDevicePicker")
                if vm.hasMic {
                    gainRow($vm.ch2Gain)
                    LevelRow(levels: { vm.micLevels() })
                }
            } header: {
                Label("Audio", systemImage: "waveform")
            }

            if !isCamera {
                Section {
                    Toggle("Keep last 15 seconds", isOn: $vm.instantReplay)
                        .onChange(of: vm.instantReplay) { _, _ in
                            if vm.isPreviewing, !vm.isRecording { Task { await vm.startPreview() } }
                        }
                } header: {
                    Label("Instant Replay", systemImage: "gobackward.15")
                } footer: {
                    Text(vm.instantReplay ? "Press ⇧⌘R to save a clip, recording or not." : "Saves a clip of what just happened with ⇧⌘R.")
                }
            }

            if vm.isRecording {
                Section {
                    Label("Locked while recording", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(vm.isRecording)
    }

    private var videoFooter: String {
        guard let size = vm.activeCaptureSize else { return "" }
        return "Capturing \(size.width)×\(size.height)."
    }

    private func devicePicker(_ title: String, selection: Binding<String?>, id: String) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(vm.availableAudioSources) { src in
                Text(src.name).tag(String?.some(src.id))
            }
        }
        .accessibilityIdentifier(id)
    }

    private func gainRow(_ gain: Binding<Double>) -> some View {
        LabeledContent("Gain") {
            HStack(spacing: 6) {
                Slider(value: gain, in: 0...1.5)
                Text("\(Int(gain.wrappedValue * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    private func restartCameraPreview() {
        if vm.isPreviewing, !vm.isRecording, vm.selectedMainSource?.kind == .camera {
            Task { await vm.startPreview() }
        }
    }
}

/// Live horizontal level meter, redrawn at 30 fps. Gradient pinned to
/// the full width so red only shows near 0 dBFS.
private struct LevelRow: View {
    let levels: () -> (rms: Float, peak: Float)?

    var body: some View {
        LabeledContent("Level") {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                let l = levels()
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(LinearGradient(
                                stops: [.init(color: .signal, location: 0), .init(color: .signal, location: 0.6),
                                        .init(color: .warningAmber, location: 0.85), .init(color: .red, location: 1)],
                                startPoint: .leading, endPoint: .trailing))
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: w * CGFloat(fraction(l?.rms ?? -120)))
                            }
                    }
                }
                .frame(height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
    }

    private func fraction(_ db: Float) -> Float { (min(max(db, -60), 0) + 60) / 60 }
}

extension CaptureResolution {
    /// Compact label for the sidebar.
    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .uhd:  return "4K"
        case .qhd:  return "1440p"
        case .fhd:  return "1080p"
        }
    }
}

extension SourceMode {
    init(_ kind: VideoSource.Kind) {
        switch kind {
        case .screenWindow:  self = .window
        case .screenDisplay: self = .screen
        case .camera:        self = .camera
        }
    }

    var sourceKind: VideoSource.Kind {
        switch self {
        case .window: return .screenWindow
        case .screen: return .screenDisplay
        case .camera: return .camera
        }
    }
}
