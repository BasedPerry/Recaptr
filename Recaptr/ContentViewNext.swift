//
//  ContentViewNext.swift
//  Recaptr
//
//  Video-first window surface. All chrome floats over the preview,
//  fades on idle, wakes on mouse move — modeled after QuickTime
//  Player's borderless playback chrome.
//
//  Surface plan (each overlay is positioned with alignment on the
//  preview):
//    Top center       — SourceSwitcherPill
//    Top right        — Settings gear (opens the Settings window)
//    Right edge       — AudioModule (gain + VU + monitor toggle)
//    Bottom center    — RecordingControlsPill
//    Bottom left      — Recording telemetry pill (only while recording)
//    Center (empty)   — "Select a source" hint when nothing is picked
//
//  Behavior:
//    - Mouse idle for `fadeDelay` seconds → chrome fades to 0 % opacity.
//    - Mouse moves (`onContinuousHover .active`) → chrome wakes.
//    - When no source is selected, chrome stays visible regardless.
//    - When recording, fade still applies; click anywhere to wake.
//    - The gear (and ⌘, from the app menu) opens the Settings window.
//
//  Paired with `.windowStyle(.hiddenTitleBar)` in RecaptrApp.swift so
//  the preview runs edge-to-edge under the traffic lights.
//

import SwiftUI
import AVFoundation

struct ContentViewNext: View {

    @EnvironmentObject var vm: MainViewModel

    /// Source sidebar open? While it is, the floating source pill
    /// steps aside (the sidebar is its expanded form).
    @Binding var sidebarVisible: Bool

    // Local UI state.
    @State private var activeMode: SourceMode = .camera
    @Environment(\.openSettings) private var openSettings

    // Fade-out behavior.
    @State private var chromeOpacity: Double = 1.0
    @State private var fadeTask: Task<Void, Never>? = nil
    private let fadeDelay: TimeInterval = 3.0

    // Soft brand-gradient halo pulsed on a successful screenshot.
    @State private var screenshotFlashOpacity: Double = 0

    // System state the chrome follows.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            // Layer 0 — graphite ground beneath the preview (visible
            // around the preview if aspect ratios disagree).
            Color.recaptrBackground.ignoresSafeArea()

            // Layer 1 — Preview surface (edge to edge).
            SampleBufferPreviewRepresentable(vm: vm)
                .ignoresSafeArea()

            // Layer 2 — Hint shown only when nothing is selected.
            if vm.selectedMainSource == nil {
                noSourceHint
            }

            // Layer 3 — Floating chrome (fades on idle).
            // One container for every floating glass surface so the
            // system renders them as a single glass layer.
            GlassEffectContainer {
                chromeLayer
            }
                // Dim when the window is inactive, like system chrome.
                .opacity(chromeOpacity * (appearsActive ? 1.0 : 0.6))
                .allowsHitTesting(chromeOpacity > 0.05)
                .animation(reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.35),
                           value: chromeOpacity)
                .animation(.easeInOut(duration: 0.2), value: appearsActive)

            // Layer 4 — screenshot flash. Brand-gradient angular
            // border, blurred for glow, pulses once on a successful
            // screenshot (~0.6 s total so it doesn't disrupt the
            // recording).
            screenshotFlashOverlay
                .allowsHitTesting(false)
        }
        .frame(minWidth: 980, minHeight: 620)
        // Mouse-move tracking that wakes the chrome and resets the
        // idle timer. `.onContinuousHover` fires continuously while
        // the mouse is moving inside the view.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                wakeChrome()
            case .ended:
                break
            }
        }
        // Window-level keyboard shortcuts:
        //   ⌘,   Settings (provided by the Settings scene's app menu item)
        //   ⌘R   Toggle record / stop
        //   ⌘K   Toggle monitor mute
        //   ⌘B   Drop clip marker
        //   ⇧⌘R  Save instant replay (last 15 s, screen sources)
        //   ⌃⌘S  Show / hide the source sidebar
        //   ⌘1   Switch to Window mode
        //   ⌘2   Switch to Screen mode
        //   ⌘3   Switch to Camera mode
        //
        // SwiftUI binds `.keyboardShortcut` to a real Button in the
        // view hierarchy; hidden buttons inside `shortcutCarrier`
        // carry the bindings without taking visual space.
        .background(shortcutCarrier)
        .overlay(alignment: .bottomTrailing) { uiTestProbe }
        .onAppear {
            syncActiveModeFromVM()
            resetFadeIfNeeded()
            vm.autoSelectAudioForCurrentSource()
        }
        .onChange(of: vm.selectedMainSource) { _, new in
            syncActiveModeFromVM()
            resetFadeIfNeeded()
            // When the video source changes, also auto-pick the
            // matching audio (camera-mode only — see
            // `MainViewModel.autoSelectAudioForCurrentSource`).
            vm.autoSelectAudioForCurrentSource()
            // Always restart preview when the source changes. Guarding
            // on `!vm.isPreviewing` here would let a source switch
            // appear to take effect in the UI while the preview surface
            // kept showing the old source; `startPreview()` handles
            // stop-then-start internally so calling it unconditionally
            // is safe.
            if new != nil {
                Task { await vm.startPreview() }
            }
        }
    }

    // MARK: - Floating chrome layer

    /// All floating glass elements positioned with alignment on the
    /// preview. Wraps a Color.clear base so overlays anchor to the
    /// available space.
    private var chromeLayer: some View {
        Color.clear
            .overlay(alignment: .top) {
                HStack(spacing: 10) {
                    sidebarButton
                    if !sidebarVisible {
                        SourceSwitcherPill(
                            activeMode: activeModeBinding,
                            sourcesForActiveMode: pickableSources(for: activeMode),
                            selectedSourceID: selectedSourceIDBinding
                        )
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: sidebarVisible ? .leading : .center)
                .padding(.leading, sidebarVisible ? 16 : 0)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: sidebarVisible)
            }
            .overlay(alignment: .topTrailing) {
                settingsButton
                    .padding(.top, 14)
                    .padding(.trailing, 16)
            }
            .overlay(alignment: .trailing) {
                // Right-edge audio surface: GAIN + live VU on top,
                // MONITOR toggle on bottom. Reads `vm.monitorEnabled`
                // and `vm.monitorVolume` directly.
                AudioModule()
                    .environmentObject(vm)
                    .padding(.trailing, 16)
            }
            .overlay(alignment: .bottom) {
                RecordingControlsPill(
                    isRecording: vm.isRecording,
                    canRecord: vm.isPreviewing || vm.selectedMainSource != nil,
                    onScreenshot: handleScreenshot,
                    onToggleRecord: handleToggleRecord,
                    onMark: handleMark
                )
                .padding(.bottom, 28)
            }
            .overlay(alignment: .bottomLeading) {
                if vm.isRecording {
                    telemetryFloating
                        .padding(.bottom, 28)
                        .padding(.leading, 20)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
    }

    // MARK: - Sidebar button

    private var sidebarButton: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(sidebarVisible ? "Hide sources (⌃⌘S)" : "Show sources and tuning (⌃⌘S)")
        .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
        .accessibilityIdentifier("sidebarToggle")
    }

    // MARK: - Gear button

    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        // System glass button: follows the Liquid Glass look setting
        // and gets the native hover / press response for free.
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settingsButton")
    }

    // MARK: - Telemetry float (only while recording)

    private var telemetryFloating: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(vm.liveStats.sessionAnchored ? 1.0 : 0.45)
                .shadow(color: .red.opacity(0.65), radius: 4)
            Text(formattedElapsed)
                .font(BrandFont.mono(weight: .medium, size: 13).swiftUI)
                .foregroundStyle(.primary)
            Text("v=\(vm.liveStats.videoAccepted) a=\(vm.liveStats.audioAccepted)")
                .font(BrandFont.mono(weight: .regular, size: 11).swiftUI)
                .foregroundStyle(.tertiary)

            // Markers count surface. Renders once at least one marker
            // has been dropped. Signal-green bookmark icon + count,
            // animates in with opacity+scale so each drop reads as a
            // visible acknowledgment.
            if !vm.markers.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.signal)
                    Text("\(vm.markers.count)")
                        .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
                        .foregroundStyle(.primary)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.35),
                   value: vm.markers.count)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Plain glass: the red dot already says "recording".
        .recaptrGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("telemetryPill")
    }

    private var formattedElapsed: String {
        let t = Int(vm.recordingElapsed)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    // MARK: - "Select a source" hint (center, no source picked)

    private var noSourceHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.fill.badge.plus")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("Select a source to begin")
                .font(BrandFont.body(weight: .medium, size: 15).swiftUI)
                .foregroundStyle(.secondary)
            Text("Pick Window, Screen, or Camera from the switcher above.")
                .font(BrandFont.body(weight: .regular, size: 12).swiftUI)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: 360)
        // Sits on the always-dark letterbox, not on glass, so pin
        // the hierarchical styles to their dark variants.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Fade behavior

    private func wakeChrome() {
        fadeTask?.cancel()
        if chromeOpacity < 0.99 {
            chromeOpacity = 1.0
        }
        scheduleFade()
    }

    /// Schedule a fade-out after `fadeDelay` seconds. Cancelled by
    /// any mouse move via `wakeChrome`.
    private func scheduleFade() {
        guard vm.selectedMainSource != nil else { return }  // keep visible when nothing selected
        // Launch argument `-RecaptrKeepChromeVisible YES` disables the
        // idle fade for UI tests and screenshot passes.
        guard !UserDefaults.standard.bool(forKey: "RecaptrKeepChromeVisible") else { return }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(fadeDelay))
            guard !Task.isCancelled else { return }
            chromeOpacity = 0.0
        }
    }

    /// Re-evaluate whether the fade should be active. Called when
    /// the selected source changes — if it just became nil, hold
    /// the chrome visible; if it just became non-nil, start the
    /// fade timer.
    private func resetFadeIfNeeded() {
        if vm.selectedMainSource == nil {
            fadeTask?.cancel()
            chromeOpacity = 1.0
        } else {
            scheduleFade()
        }
    }

    // MARK: - Mode <-> Source plumbing

    private var activeModeBinding: Binding<SourceMode> {
        Binding(
            get: { activeMode },
            set: { newMode in
                activeMode = newMode
                if newMode != .camera { vm.screenModeSelected() }
                let candidates = vm.catalog.videoSources.filter {
                    matchesMode(newMode, kind: $0.kind)
                }
                vm.selectedMainSource = candidates.first
            }
        )
    }

    private var selectedSourceIDBinding: Binding<String?> {
        Binding(
            get: { vm.selectedMainSource?.id },
            set: { newID in
                if let newID,
                   let match = vm.catalog.videoSources.first(where: { $0.id == newID }) {
                    vm.selectedMainSource = match
                } else {
                    vm.selectedMainSource = nil
                }
            }
        )
    }

    private func pickableSources(for mode: SourceMode) -> [PickableSource] {
        vm.catalog.videoSources
            .filter { matchesMode(mode, kind: $0.kind) }
            .map { PickableSource(id: $0.id, name: $0.name) }
    }

    private func matchesMode(_ mode: SourceMode, kind: VideoSource.Kind) -> Bool {
        switch (mode, kind) {
        case (.window, .screenWindow): return true
        case (.screen, .screenDisplay): return true
        case (.camera, .camera): return true
        default: return false
        }
    }

    private func syncActiveModeFromVM() {
        guard let src = vm.selectedMainSource else { return }
        switch src.kind {
        case .screenWindow:  activeMode = .window
        case .screenDisplay: activeMode = .screen
        case .camera:        activeMode = .camera
        }
    }

    // MARK: - Action handlers

    private func handleScreenshot() {
        // Captures the latest preview pixel buffer (held by
        // `vm.frameCache`) and writes PNG to the user-picked save
        // folder. On success, triggers the brand-gradient flash so
        // the user gets a visible acknowledgment.
        Task {
            do {
                _ = try await vm.captureScreenshot()
                triggerScreenshotFlash()
            } catch {
                vm.status = "Screenshot failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Screenshot flash

    /// Soft brand-gradient halo on screenshot. Thin stroke with heavy
    /// blur reads as a glow, not a border. Static (no rotation) so it
    /// breathes evenly instead of strobing; max opacity is capped well
    /// below 1.0 so the brand colors stay calm.
    private var screenshotFlashOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .restore, .violet, .signal, .restore
                    ]),
                    center: .center
                ),
                lineWidth: 8
            )
            .blur(radius: 28)
            .opacity(screenshotFlashOpacity * 0.55)
            .ignoresSafeArea()
    }

    /// Run the flash sequence. Long-ish ease-in-out on both sides
    /// (~250ms in, ~200ms hold, ~500ms out) so it reads as a calm
    /// breath rather than a snap. With Reduce Motion on, it becomes a
    /// brief static highlight with no animated ramp.
    private func triggerScreenshotFlash() {
        Task { @MainActor in
            if reduceMotion {
                screenshotFlashOpacity = 1.0
                try? await Task.sleep(for: .milliseconds(450))
                screenshotFlashOpacity = 0
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                screenshotFlashOpacity = 1.0
            }
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeInOut(duration: 0.50)) {
                screenshotFlashOpacity = 0
            }
        }
    }

    private func handleToggleRecord() {
        Task {
            if vm.isRecording {
                await vm.stopRecording()
            } else {
                // Make sure preview is running first.
                if !vm.isPreviewing {
                    await vm.startPreview()
                }
                await vm.startRecording()
            }
        }
    }

    private func handleMark() {
        // `vm.dropMarker()` appends to `vm.markers` (cleared at each
        // `startRecording`) and updates the status line.
        vm.dropMarker()
    }

    // MARK: - UI test hook

    /// With `-RecaptrUITesting YES`, exposes the last file-probe
    /// summary to accessibility so UI tests can verify what actually
    /// landed in the recorded file. Invisible and absent otherwise.
    @ViewBuilder
    private var uiTestProbe: some View {
        if UserDefaults.standard.bool(forKey: "RecaptrUITesting") {
            VStack(spacing: 0) {
                Text(vm.lastFileProbeSummary ?? "")
                    .accessibilityIdentifier("lastProbe")
                Text(vm.status)
                    .accessibilityIdentifier("statusLine")
            }
            .font(.system(size: 1))
            .opacity(0.01)
            .frame(width: 1, height: 2)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Keyboard shortcut carrier
    //
    // Hidden buttons embedded in the view hierarchy carry the
    // `.keyboardShortcut` bindings without taking visual space. Each
    // shortcut needs its own explicit Button (a ForEach loop won't
    // attach the modifier chain per-button correctly).
    private var shortcutCarrier: some View {
        Group {
            Button("") { handleToggleRecord() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("") { vm.monitorEnabled.toggle() }
                .keyboardShortcut("k", modifiers: [.command])
            Button("") { handleMark() }
                .keyboardShortcut("b", modifiers: [.command])
            Button("") { Task { await vm.saveReplay() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("") { selectMode(.window) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("") { selectMode(.screen) }
                .keyboardShortcut("2", modifiers: [.command])
            Button("") { selectMode(.camera) }
                .keyboardShortcut("3", modifiers: [.command])
            Button("") { sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// Programmatic mode-switch that mirrors what tapping a segment in
    /// the SourceSwitcherPill does — flips activeMode AND auto-picks
    /// the first available source in that mode (so ⌘1/2/3 don't leave
    /// the preview empty).
    private func selectMode(_ mode: SourceMode) {
        activeMode = mode
        if mode != .camera { vm.screenModeSelected() }
        let candidates = vm.catalog.videoSources.filter { matchesMode(mode, kind: $0.kind) }
        vm.selectedMainSource = candidates.first
    }
}

// MARK: - Preview

#Preview("Main window, Dark") {
    ContentViewNext(sidebarVisible: .constant(false))
        .environmentObject(MainViewModel())
        .frame(width: 1100, height: 700)
        .preferredColorScheme(.dark)
}

#Preview("Main window, Light") {
    ContentViewNext(sidebarVisible: .constant(false))
        .environmentObject(MainViewModel())
        .frame(width: 1100, height: 700)
        .preferredColorScheme(.light)
}

// MARK: - Root

/// Window content: the source sidebar (collapsed by default) and the
/// capture surface.
struct RecaptrRootView: View {
    @EnvironmentObject var vm: MainViewModel
    @AppStorage("RecaptrSidebarVisible") private var sidebarVisible = false

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )) {
            SourceSidebar(isVisible: $sidebarVisible)
                .navigationSplitViewColumnWidth(min: 300, ideal: 310, max: 380)
        } detail: {
            ContentViewNext(sidebarVisible: $sidebarVisible)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onAppear {
            // UI tests start from a known layout: sidebar closed. (A
            // launch argument can't do this: it would override the
            // stored value for the whole run, so toggling would fail.)
            if UserDefaults.standard.bool(forKey: "RecaptrUITesting") {
                sidebarVisible = false
            }
        }
    }
}
