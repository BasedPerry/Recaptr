//
//  SourceSwitcherPill.swift
//  Recaptr
//
//  Top-bar source switcher: a 3-segment mode selector (Window /
//  Screen / Camera) paired with a dropdown listing the available
//  sources within the active mode.
//
//  The mode selector is a custom segmented control rather than a
//  native Picker(.segmented) because macOS's segmented Picker does
//  not reliably render both an SF Symbol and a text label per
//  segment. The custom HStack version renders icon + label
//  consistently and lets each segment pick up its own brand tint
//  when active.
//

import SwiftUI

// MARK: - Mode enum

enum SourceMode: String, CaseIterable, Identifiable, Hashable {
    case window, screen, camera

    var id: Self { self }

    var label: String {
        switch self {
        case .window: return "Window"
        case .screen: return "Screen"
        case .camera: return "Camera"
        }
    }

    var systemImage: String {
        switch self {
        case .window: return "macwindow"
        case .screen: return "display"
        case .camera: return "camera.fill"
        }
    }
}

// MARK: - Source descriptor

/// Minimal shape the switcher needs to render a source menu. The
/// view model maps its richer `VideoSource` into this.
struct PickableSource: Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - Source switcher

struct SourceSwitcherPill: View {
    @Binding var activeMode: SourceMode
    /// Sources of the currently-active mode. Caller filters and maps
    /// the catalog's full source list upstream.
    var sourcesForActiveMode: [PickableSource]
    @Binding var selectedSourceID: String?

    var body: some View {
        HStack(spacing: 14) {
            modePicker
            sourceMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .brandGlassCapsule(topTint: .violet)
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(SourceMode.allCases) { mode in
                modeSegment(for: mode)
            }
        }
        .padding(3)
        .background(
            Capsule().fill(Color.white.opacity(0.04))
        )
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.18), value: activeMode)
    }

    @ViewBuilder
    private func modeSegment(for mode: SourceMode) -> some View {
        let isActive = mode == activeMode
        let tint = tintFor(mode)

        Button {
            activeMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(mode.label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isActive ? Color.graphite : Color.recaptrTextSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isActive ? tint.opacity(0.92) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.label)
    }

    /// Per-mode brand tint. Selected segment fills with this; the
    /// dropdown icon borrows it as well.
    private var activeModeTint: Color { tintFor(activeMode) }

    private func tintFor(_ mode: SourceMode) -> Color {
        switch mode {
        case .window: return .restore
        case .screen: return .violet
        case .camera: return .signal
        }
    }

    // MARK: Source menu

    private var sourceMenu: some View {
        Menu {
            if sourcesForActiveMode.isEmpty {
                Text("No \(activeMode.label.lowercased())s available")
            } else {
                ForEach(sourcesForActiveMode) { source in
                    Button {
                        selectedSourceID = source.id
                    } label: {
                        if selectedSourceID == source.id {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Text(source.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: activeMode.systemImage)
                    .imageScale(.medium)
                    .foregroundStyle(activeModeTint)
                Text(currentSourceName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 200, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.large)
    }

    private var currentSourceName: String {
        if let id = selectedSourceID,
           let match = sourcesForActiveMode.first(where: { $0.id == id }) {
            return match.name
        }
        return "Select \(activeMode.label)"
    }
}

// MARK: - Preview

#Preview("Source Switcher") {
    PreviewWrapper()
        .frame(width: 720, height: 360)
        .background(Color.recaptrBackground)
}

private struct PreviewWrapper: View {
    @State private var modeA: SourceMode = .window
    @State private var modeB: SourceMode = .screen
    @State private var modeC: SourceMode = .camera

    @State private var srcA: String? = "win-3599"
    @State private var srcB: String? = "disp-1"
    @State private var srcC: String? = "cam-4kx"

    private let windows: [PickableSource] = [
        .init(id: "win-3599", name: "Safari · #3599"),
        .init(id: "win-9785", name: "Xcode · #9785"),
        .init(id: "win-7028", name: "Terminal · #7028"),
    ]
    private let screens: [PickableSource] = [
        .init(id: "disp-1", name: "Built-in Retina"),
        .init(id: "disp-2", name: "Acer CB281HK"),
        .init(id: "disp-3", name: "Gigabyte M32U"),
    ]
    private let cameras: [PickableSource] = [
        .init(id: "cam-4kx", name: "Elgato 4K X"),
        .init(id: "cam-iphone", name: "iPhone Camera"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            stateBlock("WINDOW MODE", modeBinding: $modeA, srcBinding: $srcA, sources: windows)
            stateBlock("SCREEN MODE", modeBinding: $modeB, srcBinding: $srcB, sources: screens)
            stateBlock("CAMERA MODE", modeBinding: $modeC, srcBinding: $srcC, sources: cameras)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func stateBlock(
        _ label: String,
        modeBinding: Binding<SourceMode>,
        srcBinding: Binding<String?>,
        sources: [PickableSource]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(BrandFont.mono(weight: .regular, size: 11).swiftUI)
                .tracking(1.6)
                .foregroundStyle(Color.recaptrAccent)
            SourceSwitcherPill(
                activeMode: modeBinding,
                sourcesForActiveMode: sources,
                selectedSourceID: srcBinding
            )
        }
    }
}
