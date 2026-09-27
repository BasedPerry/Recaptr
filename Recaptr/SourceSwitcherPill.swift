//
//  SourceSwitcherPill.swift
//  Recaptr
//
//  Top-bar source switcher: a 3-segment mode selector (Window /
//  Screen / Camera) paired with a dropdown listing the available
//  sources within the active mode.
//
//  The mode selector is a custom segmented control. Retested on
//  macOS 27.0 (2026-09-26): native Picker(.segmented) still renders
//  text only (the SF Symbols are dropped) and draws its own bezel
//  track, which would sit as a second surface inside the glass pill.
//  The custom version has no track: plain segments, with the active
//  one marked by a system-accent capsule that slides between
//  segments. The accent follows the user's accent color setting.
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

    /// Brand color per source type, for icons (the sidebar's source
    /// rows and the pill's source menu). macOS 27 brought color back
    /// to sidebar icons; one color per type also tells Camera, Screen
    /// and Window apart at a glance. Selection itself stays the system
    /// accent.
    var tint: Color {
        switch self {
        case .window: return .restore
        case .screen: return .violet
        case .camera: return .signal
        }
    }
}

// MARK: - Mode segments (shared with the sidebar)

/// Window / Screen / Camera switcher. Used by the floating pill and,
/// when the sidebar is open, at the top of the sidebar (the pill's
/// expanded form), so both look and behave the same.
struct SourceModeSegments: View {
    @Binding var activeMode: SourceMode
    /// Tighter spacing for the sidebar's width.
    var compact = false

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SourceMode.allCases) { mode in
                segment(for: mode)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: activeMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture mode")
        .accessibilityIdentifier("modePicker")
    }

    private func segment(for mode: SourceMode) -> some View {
        let isActive = mode == activeMode
        return Button {
            activeMode = mode
        } label: {
            Label(mode.label, systemImage: mode.systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, compact ? 6 : 12)
                .padding(.vertical, 6)
                .frame(maxWidth: compact ? .infinity : nil)
                .background {
                    if isActive {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityIdentifier("mode-\(mode.rawValue)")
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
        .recaptrGlass()
    }

    // MARK: Mode picker

    private var modePicker: some View {
        SourceModeSegments(activeMode: $activeMode)
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
                    .foregroundStyle(activeMode.tint)
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

#Preview("Source Switcher, Dark") {
    ChromePreviewStage { SourceSwitcherPreview() }
        .frame(width: 1800, height: 360)
        .preferredColorScheme(.dark)
}

#Preview("Source Switcher, Light") {
    ChromePreviewStage { SourceSwitcherPreview() }
        .frame(width: 1800, height: 360)
        .preferredColorScheme(.light)
}

private struct SourceSwitcherPreview: View {
    @State private var modeA: SourceMode = .window
    @State private var modeB: SourceMode = .camera
    @State private var srcA: String? = "win-3599"
    @State private var srcB: String? = "cam-4kx"

    private let windows: [PickableSource] = [
        .init(id: "win-3599", name: "Safari · #3599"),
        .init(id: "win-9785", name: "Xcode · #9785"),
    ]
    private let cameras: [PickableSource] = [
        .init(id: "cam-4kx", name: "Elgato 4K X"),
        .init(id: "cam-iphone", name: "iPhone Camera"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            SourceSwitcherPill(activeMode: $modeA, sourcesForActiveMode: windows,
                               selectedSourceID: $srcA)
            SourceSwitcherPill(activeMode: $modeB, sourcesForActiveMode: cameras,
                               selectedSourceID: $srcB)
        }
    }
}
