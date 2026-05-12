//
//  SourceSwitcherPill.swift
//  Recaptr
//
//  Phase 6 — Apple-native source switcher.
//
//  Two native macOS containers paired together:
//    1. `Picker` with `.pickerStyle(.segmented)` for the mode
//       selector. This renders as native NSSegmentedControl —
//       the same control used in Finder's toolbar for view modes
//       (icons / list / columns / gallery) and in Music for
//       library views.
//    2. A `Menu` next to it lists the available sources of the
//       currently-selected mode. Renders as native NSPopUpButton —
//       the standard macOS "this is a dropdown" affordance.
//
//  Same pattern Apple uses when a sidebar collapses into a
//  toolbar pill on macOS Tahoe / Sequoia. Drop this directly
//  into a `.toolbar` ToolbarItemGroup for the full native
//  integration, or use inline like in the preview.
//
//  Public API preserved: bind to SourceMode, separately bind
//  to the selected source within that mode.
//

import SwiftUI

// MARK: - Mode enum (unchanged from v1)

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

// MARK: - Lightweight source descriptor for the menu

/// Minimal shape the switcher needs to render a source menu.
/// The MainViewModel maps its richer VideoSource into this.
struct PickableSource: Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - Source switcher (native containers)

struct SourceSwitcherPill: View {
    @Binding var activeMode: SourceMode
    /// Sources of the currently-active mode. Caller filters this
    /// upstream (e.g. catalog.videoSources.filter { $0.kind == ... }
    /// → mapped to PickableSource).
    var sourcesForActiveMode: [PickableSource]
    @Binding var selectedSourceID: String?

    var body: some View {
        HStack(spacing: 14) {
            modePicker
            sourceMenu
        }
        // Phase 6.1 — taller pill, more icon presence. Bumped vertical
        // padding from 6→11 so the top bar has actual weight over the
        // preview, and both controls ride .controlSize(.large) so the
        // SF Symbols read at glance distance.
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // True Liquid Glass — see Glass.swift. v1 stacked .regularMaterial
        // under a 0.55 solid surface fill, which is why the pill read
        // as a graphite panel instead of glass. Now it's actual translucent
        // glass with only a faint violet hero-tint at the top edge.
        .brandGlassCapsule(topTint: .violet)
    }

    // MARK: Mode picker (custom — native Picker.segmented refused to
    // render both icon AND title on macOS, no matter how loudly we
    // .labelStyle(.titleAndIcon)'d at it. Custom segmented control
    // gives us full control: real SF Symbols beside the label, brand
    // tint on the selected pill, smooth selection animation.)

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(SourceMode.allCases) { mode in
                modeSegment(for: mode)
            }
        }
        .padding(3)
        .background(
            // Inner track that the selection pill rides inside.
            // Very low-alpha so the glass capsule it sits inside is
            // still the dominant surface.
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
            // Active segment: dark text on the bright brand tint.
            // Inactive segment: muted secondary on transparent.
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

    /// Per-mode tint. Selected segment fills with this; the dropdown
    /// icon to the right of the modePicker also borrows it.
    private var activeModeTint: Color { tintFor(activeMode) }

    private func tintFor(_ mode: SourceMode) -> Color {
        switch mode {
        case .window: return .restore   // cool blue — window/structured
        case .screen: return .violet    // atmospheric — whole display
        case .camera: return .signal    // signal-green — live capture
        }
    }

    // MARK: Source menu (Menu → NSPopUpButton)

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
                    .imageScale(.medium)               // bumped from .small
                    .foregroundStyle(activeModeTint)   // mode-tinted icon
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

#Preview("Source Switcher — native Apple containers") {
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
        .init(id: "cam-iphone", name: "Brandon Perry's iPhone Camera"),
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
