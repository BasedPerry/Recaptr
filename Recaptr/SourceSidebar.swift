//
//  SourceSidebar.swift
//  Recaptr
//
//  Sidebar form of the source pill: sources, naming, and per-source tuning.
//  App-wide settings live in the Settings window.
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

    /// Follows the selected source. Setting it picks that type's first source.
    @State private var mode: SourceMode = .camera

    var body: some View {
        // One scrolling form, so tuning can't be pushed off the bottom.
        VStack(spacing: 0) {
            SourceModeSegments(activeMode: modeBinding, compact: true)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            Form {
                Section("Source") {
                    sourceRows
                }
                NamingSection()
                TuningSections()
            }
            .formStyle(.grouped)
            // Collapsed sidebar views stay alive, so stop their meters.
            .environment(\.chromeVisible, isVisible)
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
            // A menu grouped by app keeps a long window list compact.
            Picker("Window", selection: selectedID) {
                ForEach(Self.windowGroups(sources), id: \.app) { group in
                    Section(group.app) {
                        ForEach(group.windows) { window in
                            Text(Self.windowTitle(window)).tag(String?.some(window.id))
                        }
                    }
                }
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
                Label {
                    Text(Self.displayName(source))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: mode.systemImage)
                        .foregroundStyle(mode.tint)
                }
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

    /// Window names are "App: Title". Splits on the first ": " since
    /// titles may contain more.
    private static func splitWindow(_ source: VideoSource) -> (app: String, title: String) {
        let name = displayName(source)
        guard let range = name.range(of: ": ") else { return (name, name) }
        return (String(name[..<range.lowerBound]), String(name[range.upperBound...]))
    }

    static func windowTitle(_ source: VideoSource) -> String { splitWindow(source).title }

    /// Windows grouped by app, apps and titles alphabetical.
    static func windowGroups(_ sources: [VideoSource]) -> [(app: String, windows: [VideoSource])] {
        Dictionary(grouping: sources) { splitWindow($0).app }
            .map { (app: $0.key, windows: $0.value.sorted { windowTitle($0) < windowTitle($1) }) }
            .sorted { $0.app.localizedCaseInsensitiveCompare($1.app) == .orderedAscending }
    }

    /// Strips the catalog's kind prefix, which the UI already shows.
    static func displayName(_ source: VideoSource) -> String {
        for prefix in ["Camera — ", "Screen — ", "Window — "] where source.name.hasPrefix(prefix) {
            return String(source.name.dropFirst(prefix.count))
        }
        return source.name
    }
}

// MARK: - Naming

/// Series and episode names. Editable while recording because the file
/// is renamed when the take stops.
private struct NamingSection: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        Section {
            HStack(spacing: 4) {
                TextField("Series", text: $vm.seriesName, prompt: Text("None"))
                    .accessibilityIdentifier("seriesField")
                if !vm.seriesHistory.isEmpty {
                    Menu {
                        ForEach(vm.seriesHistory, id: \.self) { series in
                            Button(series) { vm.seriesName = series }
                        }
                        if !vm.seriesName.isEmpty {
                            Divider()
                            Button("No Series") { vm.seriesName = "" }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Recent series")
                }
            }
            TextField("Episode", text: $vm.episodeName, prompt: Text(episodePrompt))
                .disabled(vm.seriesName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("episodeField")
        } header: {
            Text("Recording")
        } footer: {
            Text(footer)
        }
    }

    private var aiNaming: Bool { vm.aiNamingEnabled && MarkerNamer.isAvailable }

    private var episodePrompt: String {
        "Auto"
    }

    private var footer: String {
        let series = SessionNaming.sanitize(vm.seriesName)
        let ai = "Markers are named with Apple Intelligence after you stop."
        guard !series.isEmpty else {
            return "Add a series to file recordings together." + (aiNaming ? " " + ai : "")
        }
        let typed = SessionNaming.sanitize(vm.episodeName)
        let episode = !typed.isEmpty ? typed : aiNaming ? "Ep N – Title" : "Ep N"
        return "Saves as \(series)/\(SessionNaming.baseName(series: series, episode: episode)).mov"
    }
}

// MARK: - Tuning

/// Video, audio, and instant replay settings for the selected source type.
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
                    // Webcams only; capture cards don't support it.
                    if vm.lowLightNoiseReductionSupported {
                        Toggle("Low-light cleanup", isOn: $vm.lowLightNoiseReduction)
                            .onChange(of: vm.lowLightNoiseReduction) { _, _ in restartCameraPreview() }
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text(videoFooter)
                }
            } else {
                Section {
                    Picker("Resolution", selection: $vm.screenResolution) {
                        ForEach(ScreenResolution.allCases) { Text($0.shortLabel).tag($0) }
                    }
                    .onChange(of: vm.screenResolution) { _, _ in restartScreenPreview() }
                    Picker("Frame rate", selection: $vm.screenFrameRate) {
                        Text("60 fps").tag(60)
                        Text("30 fps").tag(30)
                    }
                    .onChange(of: vm.screenFrameRate) { _, _ in restartScreenPreview() }
                    Toggle("Show cursor", isOn: $vm.screenShowsCursor)
                        .onChange(of: vm.screenShowsCursor) { _, _ in restartScreenPreview() }
                    // Never recorded. Green while previewing, red while recording.
                    Toggle("Outline what's captured", isOn: $vm.showCaptureOutline)
                } header: {
                    Text("Video")
                } footer: {
                    Text(screenVideoFooter)
                }
            }

            Section {
                if isCamera {
                    // "Input", not "Source", to avoid confusion with the video source.
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
                Text("Audio")
            }

            if !isCamera {
                Section {
                    Toggle("Keep last 15 seconds", isOn: $vm.instantReplay)
                        .onChange(of: vm.instantReplay) { _, _ in
                            if vm.isPreviewing, !vm.isRecording { Task { await vm.startPreview() } }
                        }
                } header: {
                    Text("Instant Replay")
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

    /// Shows the actual size, since Auto keeps the source's own size up to 4K.
    private var screenVideoFooter: String {
        // Empty until capture starts, so it doesn't flash on every switch.
        guard let size = vm.activeCaptureSize else { return "" }
        return "Capturing \(size.width)×\(size.height) at \(vm.screenFrameRate) fps."
    }

    private func restartScreenPreview() {
        if vm.isPreviewing, !vm.isRecording, vm.selectedMainSource?.kind != .camera {
            Task { await vm.startPreview() }
        }
    }

    private func restartCameraPreview() {
        if vm.isPreviewing, !vm.isRecording, vm.selectedMainSource?.kind == .camera {
            Task { await vm.startPreview() }
        }
    }
}

/// Live horizontal level meter.
private struct LevelRow: View {
    let levels: () -> (rms: Float, peak: Float)?
    @Environment(\.chromeVisible) private var visible

    var body: some View {
        LabeledContent("Level") {
            LevelMeter(levels: levels, active: visible, vertical: false, thickness: 6, showsPeak: false, label: "Level")
                .frame(height: 6)
        }
    }
}

extension CaptureResolution {
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
