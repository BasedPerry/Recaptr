//
//  ContentViewNext.swift
//  Recaptr
//
//  Phase 6 — Pure QuickTime layout. Video-first surface with all
//  chrome floating over the preview, fading on idle, waking on
//  mouse move. Inspired by QuickTime Player and the iOS Camera /
//  Photos slideshow patterns.
//
//  Surface plan (each overlay is positioned with alignment on the
//  preview):
//    Top center       — SourceSwitcherPill
//    Top right        — Settings gear (opens SettingsPopover)
//    Right edge       — AudioModule (vertically centered) — Phase 6.3
//                       replaced VolumeBar; surfaces input gain + live
//                       VU + monitor toggle as first-class controls.
//    Bottom center    — RecordingControlsPill
//    Bottom left      — Recording telemetry pill (only while recording)
//    Center (empty)   — "Select a source" hint when nothing is picked
//
//  Behavior:
//    - Mouse idle for `fadeDelay` seconds → chrome fades to 0% opacity.
//    - Mouse moves (`onContinuousHover .active`) → chrome wakes.
//    - When no source is selected, chrome stays visible regardless.
//    - When recording, fade still applies; click anywhere to wake.
//    - ⌘, opens the settings popover (standard macOS shortcut).
//
//  Window-level: paired with `.windowStyle(.hiddenTitleBar)` in
//  RecaptrApp.swift so the preview goes edge-to-edge under the
//  traffic lights, matching QuickTime Player's borderless feel.
//

import SwiftUI
import AVFoundation

struct ContentViewNext: View {

    @EnvironmentObject var vm: MainViewModel

    // Local UI state for the new pills.
    @State private var activeMode: SourceMode = .camera
    @State private var showSettings: Bool = false
    // Phase 6.3 — `isMixerOpen` / `monitorMuted` removed alongside the
    // VolumeBar → AudioModule swap. AudioModule reads vm.monitorEnabled
    // and vm.monitorVolume directly; gear button is the single entry
    // point to the settings popover now.

    // Fade-out behavior.
    @State private var chromeOpacity: Double = 1.0
    @State private var fadeTask: Task<Void, Never>? = nil
    private let fadeDelay: TimeInterval = 3.0

    // Phase 6.5.1 — screenshot flash. Soft brand-gradient halo that
    // breathes in and out on capture. v1 used a rotating angular
    // gradient at full opacity, which read as a flicker; v2 keeps
    // the gradient static and softens it to a calm glow.
    @State private var screenshotFlashOpacity: Double = 0

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
            chromeLayer
                .opacity(chromeOpacity)
                .allowsHitTesting(chromeOpacity > 0.05)
                .animation(.easeInOut(duration: 0.35), value: chromeOpacity)

            // Layer 4 — Phase 6.5.1 screenshot flash. Brand-gradient
            // angular border, blurred for glow, pulses once on
            // successful screenshot. Inspired by Apple Intelligence's
            // living-color edge treatment but tuned to a quick punch
            // (~0.6s total) so it doesn't disrupt the recording.
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
        // Phase 6.4 — window-level keyboard shortcuts.
        //   ⌘,   Settings (Apple convention)
        //   ⌘R   Toggle record / stop
        //   ⌘K   Toggle monitor mute (matches OBS, matches AudioModule pill)
        //   ⌘B   Drop clip marker
        //   ⌘1   Switch to Window mode
        //   ⌘2   Switch to Screen mode
        //   ⌘3   Switch to Camera mode
        // Hidden Buttons embedded in the view hierarchy carry the
        // shortcut bindings — same pattern Apple uses for menu-less
        // single-window apps.
        .background(shortcutCarrier)
        .onAppear {
            syncActiveModeFromVM()
            resetFadeIfNeeded()
            vm.autoSelectAudioForCurrentSource()
        }
        .onChange(of: vm.selectedMainSource) { _, new in
            syncActiveModeFromVM()
            resetFadeIfNeeded()
            // Phase 6.2 / Task #16 — when video source changes, also
            // auto-pick the matching audio (camera-mode only; see
            // MainViewModel.autoSelectAudioForCurrentSource doc).
            vm.autoSelectAudioForCurrentSource()
            // Phase 6.6.2 — always restart preview when source changes.
            // Previously this had a `!vm.isPreviewing` guard which meant
            // switching from Elgato to a Window while preview was already
            // running silently did nothing — UI selection moved, preview
            // surface kept showing the old source. startPreview() handles
            // the stop-then-start internally so calling it unconditionally
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
                SourceSwitcherPill(
                    activeMode: activeModeBinding,
                    sourcesForActiveMode: pickableSources(for: activeMode),
                    selectedSourceID: selectedSourceIDBinding
                )
                .padding(.top, 14)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
            }
            .overlay(alignment: .topTrailing) {
                settingsButton
                    .padding(.top, 14)
                    .padding(.trailing, 16)
            }
            .overlay(alignment: .trailing) {
                // Phase 6.3 — replaced VolumeBar with AudioModule.
                // The right-edge audio surface now shows GAIN +
                // live VU on top, MONITOR toggle on bottom. The old
                // VolumeBar conflated "volume" with "monitor volume"
                // and buried input gain inside the Settings popover —
                // both fixed here.
                AudioModule()
                    .environmentObject(vm)
                    .padding(.trailing, 16)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
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
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
            }
            .overlay(alignment: .bottomLeading) {
                if vm.isRecording {
                    telemetryFloating
                        .padding(.bottom, 28)
                        .padding(.leading, 20)
                        .shadow(color: .black.opacity(0.40), radius: 10, y: 3)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
    }

    // MARK: - Gear button + popover

    private var settingsButton: some View {
        Button {
            showSettings.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.recaptrTextSecondary)
                .frame(width: 40, height: 40)
                // True Liquid Glass circle — matches the three pills.
                .background(
                    Group {
                        if #available(macOS 26.0, *) {
                            Color.clear.glassEffect().clipShape(Circle())
                        } else {
                            VisualEffectView(material: .hudWindow,
                                             blending: .withinWindow)
                                .clipShape(Circle())
                        }
                    }
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            SettingsPopover()
                .environmentObject(vm)
                .frame(idealWidth: 420)
        }
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
                .foregroundStyle(Color.recaptrTextPrimary)
            Text("v=\(vm.liveStats.videoAccepted) a=\(vm.liveStats.audioAccepted)")
                .font(BrandFont.mono(weight: .regular, size: 11).swiftUI)
                .foregroundStyle(Color.recaptrTextMuted)

            // Phase 6.5 — markers count surface. Only renders once
            // at least one marker has been dropped. Signal-green
            // bookmark icon + count, animates in with opacity+scale
            // so each drop has a perceptible visual acknowledgment.
            if !vm.markers.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.signal)
                    Text("\(vm.markers.count)")
                        .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
                        .foregroundStyle(Color.recaptrTextPrimary)
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0.35), value: vm.markers.count)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // True Liquid Glass — same modifier as the three main pills.
        // Red dot + mono telemetry now sit on real glass instead of
        // a graphite panel.
        .brandGlassCapsule(topTint: .red)
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
                .foregroundStyle(Color.recaptrTextMuted)
            Text("Select a source to begin")
                .font(BrandFont.body(weight: .medium, size: 15).swiftUI)
                .foregroundStyle(Color.recaptrTextSecondary)
            Text("Pick Window, Screen, or Camera from the switcher above.")
                .font(BrandFont.body(weight: .regular, size: 12).swiftUI)
                .foregroundStyle(Color.recaptrTextMuted)
        }
        .padding(24)
        .frame(maxWidth: 360)
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
        // Phase 6.5 — real screenshot. Captures the latest preview
        // pixel buffer (held by vm.frameCache) and writes PNG to the
        // user-picked save folder. On success, triggers the brand-
        // gradient flash so the user gets visible acknowledgment.
        Task {
            do {
                _ = try await vm.captureScreenshot()
                triggerScreenshotFlash()
            } catch {
                vm.status = "Screenshot failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Phase 6.5.1 — screenshot flash

    /// Soft brand-gradient halo on screenshot. Thin stroke with heavy
    /// blur reads as a glow, not a border. Static (no rotation) so it
    /// breathes evenly instead of strobing. Max opacity is capped well
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
    /// breath rather than a snap.
    private func triggerScreenshotFlash() {
        Task { @MainActor in
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
        // Phase 6.5 — real marker persistence. vm.dropMarker() appends
        // to vm.markers (cleared at each startRecording) and updates
        // the status line. Phase 7c sidebar will surface the list.
        vm.dropMarker()
    }

    // MARK: - Phase 6.4 — Keyboard shortcut carrier
    //
    // SwiftUI binds `.keyboardShortcut` to a real Button in the view
    // hierarchy. Hidden buttons inside a Group on .background carry
    // the bindings without taking visual space. Buttons must have
    // identifiable structure (not just a ForEach) for the modifier
    // chain to attach properly per-button, so each shortcut is its
    // own explicit Button.
    private var shortcutCarrier: some View {
        Group {
            Button("") { showSettings.toggle() }
                .keyboardShortcut(",", modifiers: [.command])
            Button("") { handleToggleRecord() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("") { vm.monitorEnabled.toggle() }
                .keyboardShortcut("k", modifiers: [.command])
            Button("") { handleMark() }
                .keyboardShortcut("b", modifiers: [.command])
            Button("") { selectMode(.window) }
                .keyboardShortcut("1", modifiers: [.command])
            Button("") { selectMode(.screen) }
                .keyboardShortcut("2", modifiers: [.command])
            Button("") { selectMode(.camera) }
                .keyboardShortcut("3", modifiers: [.command])
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
        let candidates = vm.catalog.videoSources.filter { matchesMode(mode, kind: $0.kind) }
        vm.selectedMainSource = candidates.first
    }
}

// MARK: - Preview

#Preview("ContentViewNext — QuickTime layout") {
    ContentViewNext()
        .environmentObject(MainViewModel())
        .frame(width: 1100, height: 700)
}
