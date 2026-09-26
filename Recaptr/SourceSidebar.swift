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
        // Switcher on top, that type's sources in the middle, that
        // type's tuning at the bottom (not an overlay, which let list
        // rows scroll under its text).
        VStack(spacing: 0) {
            SourceModeSegments(activeMode: modeBinding, compact: true)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            List(selection: selectedID) {
                sourceList
            }
            .listStyle(.sidebar)
            // On the list only: on the container it overrides every
            // control's own identifier.
            .accessibilityIdentifier("sourceSidebar")

            TuningPanel()
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
    private var sourceList: some View {
        let kind = mode.sourceKind
        let sources = vm.catalog.videoSources.filter { $0.kind == kind }
        if kind != .camera && !vm.screenCapturePermissionGranted {
            Button {
                vm.screenModeSelected()
            } label: {
                Label("Allow Screen Recording…", systemImage: "lock")
            }
            .buttonStyle(.borderless)
            .selectionDisabled()
        } else if sources.isEmpty {
            Text(kind == .camera ? "No cameras connected" : kind == .screenDisplay ? "No displays" : "No windows open")
                .foregroundStyle(.tertiary)
                .selectionDisabled()
        } else {
            ForEach(sources) { source in
                Label(Self.displayName(source), systemImage: mode.systemImage)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tag(source.id)
                    .help(source.name)
            }
        }
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

/// Per-method tuning, pinned under the source list.
private struct TuningPanel: View {
    @EnvironmentObject var vm: MainViewModel

    private var kind: VideoSource.Kind? { vm.selectedMainSource?.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            if let kind {
                header(kind == .camera ? "Camera" : kind == .screenDisplay ? "Screen" : "Window")
                if kind == .camera { cameraTuning } else { screenTuning }
            }
            header("Commentary mic")
            devicePicker(selection: $vm.ch2DeviceID, id: "micDevicePicker")
            gainRow($vm.ch2Gain)
            if vm.isRecording {
                Label("Locked while recording", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .controlSize(.small)
        .disabled(vm.isRecording)
    }

    @ViewBuilder
    private var cameraTuning: some View {
        LabeledContent("Resolution") {
            Picker("Resolution", selection: $vm.captureResolution) {
                ForEach(CaptureResolution.allCases) { Text($0.shortLabel).tag($0) }
            }
            .labelsHidden()
        }
        .onChange(of: vm.captureResolution) { _, _ in restartCameraPreview() }

        if let size = vm.activeCaptureSize {
            Text("Capturing \(size.width)×\(size.height)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Toggle("Low-light noise reduction", isOn: $vm.lowLightNoiseReduction)
            .disabled(!vm.lowLightNoiseReductionSupported)
            .help(vm.lowLightNoiseReductionSupported
                  ? "Cleans up grain in dim webcam footage. Changes the image."
                  : "Not supported by this camera (capture cards don't offer it).")
            .onChange(of: vm.lowLightNoiseReduction) { _, _ in restartCameraPreview() }

        LabeledContent("Source audio") {
            devicePicker(selection: $vm.ch1DeviceID, id: "sourceDevicePicker")
                .labelsHidden()
        }
        gainRow($vm.ch1Gain)
    }

    @ViewBuilder
    private var screenTuning: some View {
        Toggle("Instant replay", isOn: $vm.instantReplay)
            .help("Keeps the last 15 seconds in memory. ⇧⌘R saves it as a clip.")
            .onChange(of: vm.instantReplay) { _, _ in
                if vm.isPreviewing, !vm.isRecording { Task { await vm.startPreview() } }
            }
        Text(vm.instantReplay ? "⇧⌘R saves the last 15 seconds." : "Records system audio from the shared screen or window.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Pieces

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func devicePicker(selection: Binding<String?>, id: String) -> some View {
        Picker("Device", selection: selection) {
            Text("None").tag(String?.none)
            ForEach(vm.availableAudioSources) { src in
                Text(src.name).tag(String?.some(src.id))
            }
        }
        .accessibilityIdentifier(id)
    }

    private func gainRow(_ gain: Binding<Double>) -> some View {
        HStack {
            Image(systemName: "speaker.wave.1")
                .foregroundStyle(.secondary)
            Slider(value: gain, in: 0...1.5)
            Text("\(Int(gain.wrappedValue * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Gain")
    }

    private func restartCameraPreview() {
        if vm.isPreviewing, !vm.isRecording, vm.selectedMainSource?.kind == .camera {
            Task { await vm.startPreview() }
        }
    }
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
