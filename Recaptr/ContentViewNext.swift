//
//  ContentViewNext.swift
//  Recaptr
//
//  Main window: full-bleed preview with floating chrome that fades on idle.
//

import SwiftUI
import AVFoundation

struct ContentViewNext: View {

    @EnvironmentObject var vm: MainViewModel

    /// The floating source pill hides while the sidebar is open.
    @Binding var sidebarVisible: Bool

    @State private var activeMode: SourceMode = .camera
    @Environment(\.openSettings) private var openSettings

    @State private var chromeOpacity: Double = 1.0
    @State private var fadeTask: Task<Void, Never>? = nil
    private let fadeDelay: TimeInterval = 3.0

    @State private var screenshotFlashOpacity: Double = 0
    @State private var markerFlashOpacity: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.recaptrBackground.ignoresSafeArea()

            // Aspect ratio first, then clip, so the rounded corners land
            // on the picture and not the letterbox. Preview only; the
            // recording is not affected.
            SampleBufferPreviewRepresentable(vm: vm)
                .aspectRatio(previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()

            if vm.selectedMainSource == nil {
                noSourceHint
            }

            // One container so the system renders all floating glass as
            // one layer. Don't add inactive-window dimming: glass already
            // dims itself, and doubling it makes the controls unreadable.
            GlassEffectContainer {
                chromeLayer
            }
                // Live meters pause while the chrome is faded out.
                .environment(\.chromeVisible, chromeOpacity > 0.05)
                .opacity(chromeOpacity)
                .allowsHitTesting(chromeOpacity > 0.05)
                .animation(reduceMotion ? .linear(duration: 0.1) : .easeInOut(duration: 0.35),
                           value: chromeOpacity)

            // Outside the fading chrome so elapsed time stays visible.
            if vm.isRecording {
                telemetryFloating
                    .padding(.bottom, 28)
                    .padding(.leading, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .bottom)))
            }

            screenshotFlashOverlay
                .allowsHitTesting(false)

            // Only in the hierarchy while it plays, so it costs nothing otherwise.
            if markerFlashOpacity > 0 {
                markerFlashOverlay
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: vm.isRecording)
        .onChange(of: vm.markers.count) { old, new in
            if new > old { triggerMarkerFlash() }
        }
        .frame(minWidth: 980, minHeight: 620)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                wakeChrome()
            case .ended:
                break
            }
        }
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
            vm.autoSelectAudioForCurrentSource()
            // Restart unconditionally. Guarding on `isPreviewing` leaves
            // the old source on screen; startPreview() stops first itself.
            if new != nil {
                Task { await vm.startPreview() }
            }
        }
    }

    // MARK: - Floating chrome layer

    /// Floating controls, anchored by overlay alignment on a clear base.
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
    }

    /// Width ÷ height of what's being captured (16:9 until known).
    private var previewAspect: CGFloat {
        guard let size = vm.activeCaptureSize, size.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(size.width) / CGFloat(size.height)
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settingsButton")
    }

    // MARK: - Recording status

    private var telemetryFloating: some View {
        RecordingPill(clock: vm.clock, markerCount: vm.markers.count)
    }

    // MARK: - No-source hint

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
        // Sits on the always-dark letterbox, not glass.
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

    private func scheduleFade() {
        guard vm.selectedMainSource != nil else { return }
        // `-RecaptrKeepChromeVisible YES` disables the fade for UI tests and screenshots.
        guard !UserDefaults.standard.bool(forKey: "RecaptrKeepChromeVisible") else { return }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(fadeDelay))
            guard !Task.isCancelled else { return }
            chromeOpacity = 0.0
        }
    }

    /// Chrome stays visible while no source is selected.
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
            // The mode segment already names the kind, so drop the prefix.
            .map { PickableSource(id: $0.id, name: SourceSidebar.displayName($0)) }
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

    /// Brand-gradient glow on a successful screenshot. Opacity is capped
    /// so the colors stay soft.
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

    /// About 250 ms in, 200 ms hold, 500 ms out. Reduce Motion shows a
    /// brief static highlight instead.
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

    // MARK: - Marker flash

    /// Green edge glow when a marker lands. Stacked strokes instead of a
    /// blur: a full-window blur re-filters every frame of the fade.
    private var markerFlashOverlay: some View {
        ZStack {
            Rectangle().strokeBorder(Color.signal.opacity(0.16), lineWidth: 30)
            Rectangle().strokeBorder(Color.signal.opacity(0.30), lineWidth: 14)
            Rectangle().strokeBorder(Color.signal.opacity(0.85), lineWidth: 4)
        }
        .compositingGroup()
        .opacity(markerFlashOpacity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func triggerMarkerFlash() {
        Task { @MainActor in
            // `-RecaptrUITestHoldMarkerFlash YES` holds the glow 4 s for screenshots.
            let d = UserDefaults.standard
            if d.bool(forKey: "RecaptrUITesting"), d.bool(forKey: "RecaptrUITestHoldMarkerFlash") {
                markerFlashOpacity = 1
                try? await Task.sleep(for: .seconds(4))
                markerFlashOpacity = 0
                return
            }
            if reduceMotion {
                markerFlashOpacity = 1
                try? await Task.sleep(for: .milliseconds(350))
                markerFlashOpacity = 0
                return
            }
            withAnimation(.easeOut(duration: 0.1)) { markerFlashOpacity = 1 }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeIn(duration: 0.45)) { markerFlashOpacity = 0.0001 }
            try? await Task.sleep(for: .milliseconds(460))
            markerFlashOpacity = 0
        }
    }

    private func handleToggleRecord() {
        Task {
            if vm.isRecording {
                await vm.stopRecording()
            } else {
                if !vm.isPreviewing {
                    await vm.startPreview()
                }
                await vm.startRecording()
            }
        }
    }

    private func handleMark() {
        vm.dropMarker()
    }

    // MARK: - UI test hook

    /// With `-RecaptrUITesting YES`, exposes the last file probe and
    /// status line to accessibility for UI tests. Absent otherwise.
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

    // MARK: - Keyboard shortcuts

    /// Hidden buttons that carry the window's shortcuts. Each needs its
    /// own Button; a ForEach doesn't attach the shortcuts reliably.
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

    /// Same as tapping a switcher segment: also picks the first source
    /// so ⌘1/2/3 don't leave the preview empty.
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
    @AppStorage(WelcomeSheet.seenKey) private var welcomeSeen = false

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
        .sheet(isPresented: Binding(
            get: { !welcomeSeen && !UserDefaults.standard.bool(forKey: "RecaptrUITesting") },
            set: { if !$0 { welcomeSeen = true } }
        )) {
            WelcomeSheet()
                .environmentObject(vm)
        }
        .onAppear {
            // UI tests start with the sidebar closed. Not a launch
            // argument: that would pin the value and break toggling.
            if UserDefaults.standard.bool(forKey: "RecaptrUITesting") {
                sidebarVisible = false
            }
        }
    }
}

extension EnvironmentValues {
    /// Whether the floating chrome is showing. Live meters pause when it isn't.
    @Entry var chromeVisible: Bool = true
}

/// Red dot, elapsed time, file size, marker count. Observes only the
/// clock so its once-a-second tick doesn't redraw the window.
private struct RecordingPill: View {
    @ObservedObject var clock: RecordingClock
    let markerCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(clock.anchored ? 1.0 : 0.45)
            Text(clock.formattedElapsed)
                .font(BrandFont.mono(weight: .medium, size: 13).swiftUI)
                .foregroundStyle(.primary)
                .monospacedDigit()
            if clock.bytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: clock.bytes, countStyle: .file))
                    .font(BrandFont.mono(weight: .regular, size: 11).swiftUI)
                    .foregroundStyle(.secondary)
            }
            if markerCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.signal)
                    Text("\(markerCount)")
                        .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
                        .foregroundStyle(.primary)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.35), value: markerCount)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .recaptrGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("telemetryPill")
    }
}
