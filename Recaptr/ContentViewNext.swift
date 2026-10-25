//
//  ContentViewNext.swift
//  Recaptr
//
//  Main window: full-bleed preview with floating chrome that hides on idle.
//  Mid-take, the bottom bar morphs into a small recording pill.
//

import SwiftUI
import AVFoundation

struct ContentViewNext: View {

    @EnvironmentObject var vm: MainViewModel

    /// The floating source pill hides while the sidebar is open.
    @Binding var sidebarVisible: Bool

    @State private var activeMode: SourceMode = .camera
    @Environment(\.openSettings) private var openSettings

    @State private var chromeShown = true
    @Namespace private var glassSpace
    @State private var fadeTask: Task<Void, Never>? = nil
    private let fadeDelay: TimeInterval = 3.0

    @AppStorage(PillTuck.key, store: TestHooks.preferences) private var tuck = PillTuck.center
    @AppStorage(PillTuck.yKey, store: TestHooks.preferences) private var tuckY = 0.5
    @State private var pillDrag: CGSize = .zero
    @State private var tabDragY: CGFloat? = nil
    @State private var windowSize: CGSize = .zero
    @State private var windowDisplay: CGDirectDisplayID?
    /// The marker whose title is being typed ("I'll name them").
    @State private var titlingMarker: Int?

    @State private var screenshotFlashOpacity: Double = 0
    @State private var markerFlashOpacity: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if DEBUG
    @AppStorage(GlassTest.key) private var glassTest = GlassTest.standard
    @AppStorage(GlassTest.keepChromeKey) private var debugKeepChromeOn = false
    #endif

    var body: some View {
        ZStack {
            Color.recaptrBackground.ignoresSafeArea()

            // Aspect ratio first, then clip, so the rounded corners land
            // on the picture and not the letterbox. Preview only; the
            // recording is not affected.
            if debugShowsGradient {
                LinearGradient(colors: [.orange, .pink, .purple, .blue],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            } else {
                SampleBufferPreviewRepresentable(vm: vm)
                    .aspectRatio(previewAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
                    // Mid-take the mouse alone doesn't bring the controls back.
                    .contentShape(Rectangle())
                    .onTapGesture { wakeChrome() }
            }

            if vm.selectedMainSource == nil {
                noSourceHint
            }

            // One container so the system renders all floating glass as
            // one layer. Don't add inactive-window dimming: glass already
            // dims itself, and doubling it makes the controls unreadable.
            Group {
                if debugSkipsContainer {
                    chromeLayer
                } else {
                    GlassEffectContainer { chromeLayer }
                }
            }
                // Live meters pause while the chrome is hidden.
                .environment(\.chromeVisible, chromeShown)

            screenshotFlashOverlay
                .allowsHitTesting(false)

            // Only in the hierarchy while it plays, so it costs nothing otherwise.
            if markerFlashOpacity > 0 {
                markerFlashOverlay
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.pick(Motion.fade, reduceMotion: reduceMotion), value: vm.isRecording)
        .onChange(of: vm.markers.count) { old, new in
            if new > old {
                triggerMarkerFlash()
                askForMarkerTitle(new - 1)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                // Mid-take, once the controls hide, moving over the game
                // leaves them hidden. A click on the pill or the picture
                // brings them back.
                if vm.isRecording, !chromeShown { break }
                wakeChrome()
            case .ended:
                break
            }
        }
        .background(shortcutCarrier)
        .overlay(alignment: .bottomTrailing) { uiTestProbe }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            windowDisplay = SelfCapture.windowDisplay
        }
        .onChange(of: vm.isRecording) { _, recording in
            if !recording { titlingMarker = nil }
            SelfCapture.follow(isRecording: recording, source: vm.selectedMainSource)
        }
        .onChange(of: vm.requestedMode) { _, request in
            if let request { activeMode = request.mode }
        }
        .onChange(of: vm.presentedTake?.url) { _, url in
            if url != nil { fadeTask?.cancel(); setChrome(shown: true) } else { scheduleFade() }
        }
        .onChange(of: debugKeepsChrome) { _, keep in
            if keep { fadeTask?.cancel(); setChrome(shown: true) } else { scheduleFade() }
        }
        .onAppear {
            windowDisplay = SelfCapture.windowDisplay
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
            // Never mid-take: a restart would end the recording.
            if new != nil, !vm.isRecording {
                Task { await vm.startPreview() }
            }
        }
    }

    // MARK: - Debug → Glass Test

    #if DEBUG
    private var debugShowsGradient: Bool { glassTest == .noVideo }
    private var debugSkipsContainer: Bool { glassTest == .noContainer }
    /// Also `-RecaptrKeepChromeVisible YES`, for UI tests and screenshots.
    private var debugKeepsChrome: Bool {
        debugKeepChromeOn || glassTest != .standard
            || UserDefaults.standard.bool(forKey: "RecaptrKeepChromeVisible")
    }
    #else
    private let debugShowsGradient = false
    private let debugSkipsContainer = false
    private let debugKeepsChrome = false
    #endif

    // MARK: - Floating chrome layer

    /// Floating controls, anchored by overlay alignment on a clear base.
    private var chromeLayer: some View {
        Color.clear
            // Hidden controls leave the container, so their glass dissolves
            // rather than fading.
            // The switcher centers on the picture; the round buttons sit
            // in the corners so they don't push it off center.
            .overlay(alignment: .top) {
                if chromeShown, !sidebarVisible {
                    SourceSwitcherPill(
                        activeMode: activeModeBinding,
                        sourcesForActiveMode: pickableSources(for: activeMode),
                        selectedSourceID: selectedSourceIDBinding
                    )
                    // Changing source restarts capture, which would end the take.
                    .disabled(vm.isRecording)
                    .help(vm.isRecording ? "Stop recording to change the source" : "")
                    .padding(.top, 14)
                }
            }
            .overlay(alignment: .topLeading) {
                if chromeShown {
                    sidebarButton
                        .padding(.top, 14)
                        .padding(.leading, 16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if chromeShown {
                    settingsButton
                        .padding(.top, 14)
                        .padding(.trailing, 16)
                }
            }
            .overlay(alignment: .bottom) {
                bottomGlass
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .overlay(alignment: tuck == .left ? .topLeading : .topTrailing) {
                tuckedTab
            }
            // Notices stay visible when the rest of the chrome hides.
            .overlay(alignment: .top) {
                if let notice = vm.notice {
                    NoticeBanner(notice: notice, onFix: handleFix) {
                        withAnimation(chromeAnimation) { vm.notice = nil }
                    }
                    .padding(.top, 70)
                    .padding(.horizontal, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    // Plain confirmations close themselves; problems stay until closed.
                    .task(id: notice.id) {
                        guard notice.autoCloses else { return }
                        try? await Task.sleep(for: .seconds(4))
                        if vm.notice?.id == notice.id { withAnimation(chromeAnimation) { vm.notice = nil } }
                    }
                }
            }
            .animation(chromeAnimation, value: vm.notice)
    }

    /// The bar while the chrome shows. Mid-take, once it hides, the same
    /// glass flows into the recording pill.
    private var bottomGlass: some View {
        VStack(spacing: 12) {
            if vm.isRecording, let index = titlingMarker {
                MarkerTitleField(number: index + 1, title: markerTitleBinding(index),
                                 onDone: { withAnimation(chromeAnimation) { titlingMarker = nil } },
                                 onSkip: {
                                     vm.markerTitles[index] = nil
                                     withAnimation(chromeAnimation) { titlingMarker = nil }
                                 })
                    .id(index)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if chromeShown, !vm.isRecording, vm.presentedTake == nil, capturesOwnScreen {
                SelfCaptureHint()
                    .transition(.opacity)
            }
            if chromeShown, let take = vm.presentedTake {
                AfterTakeCard(take: take, glassNamespace: glassSpace) {
                    withAnimation(chromeAnimation) { vm.presentedTake = nil }
                }
                .environmentObject(vm)
                .transition(reduceMotion ? .opacity
                                         : .move(edge: .bottom).combined(with: .opacity))
            }
            barOrPill
        }
        .animation(chromeAnimation, value: vm.presentedTake?.url)
    }

    @ViewBuilder
    private var barOrPill: some View {
        if chromeShown {
            BottomBar(onScreenshot: handleScreenshot,
                      onToggleRecord: handleToggleRecord,
                      onMark: handleMark,
                      glassNamespace: glassSpace)
                .environmentObject(vm)
        } else if vm.isRecording, tuck == .center {
            RecordingPill(clock: vm.clock, markerCount: vm.markers.count, glassNamespace: glassSpace)
                .offset(pillDrag)
                .gesture(pillDragGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { wakeChrome() }
                .accessibilityAction(named: "Tuck to Left Edge") { setTuck(.left) }
                .accessibilityAction(named: "Tuck to Right Edge") { setTuck(.right) }
        }
    }

    // MARK: - Tucking the pill

    /// The tucked tab, on its edge at its remembered height.
    @ViewBuilder
    private var tuckedTab: some View {
        if !chromeShown, vm.isRecording, tuck != .center {
            let y = tabDragY ?? PillTuck.tabY(fraction: tuckY, height: windowSize.height)
            TuckedTab(clock: vm.clock, edge: tuck, glassNamespace: glassSpace)
                // Centered on `y`, flush with the edge.
                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                .offset(y: y)
                .gesture(tabDragGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Recording. Show the recording pill")
                .accessibilityAction { setTuck(.center) }
                .transition(reduceMotion ? .opacity
                                         : .move(edge: tuck == .left ? .leading : .trailing))
        }
    }

    // Gestures work from the drag distance: the pill always starts at the
    // bottom center and the tab at its stored height.
    /// One gesture for click and drag: a press that barely moves is a click.
    private var pillDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if Self.isDrag(value.translation) { pillDrag = value.translation }
            }
            .onEnded { value in
                guard Self.isDrag(value.translation) else { wakeChrome(); return }
                // A flick toward an edge counts where it was headed.
                let x = windowSize.width / 2 + value.predictedEndTranslation.width
                let y = windowSize.height - Self.pillCenterFromBottom + value.translation.height
                let side = PillTuck.landing(x: x, width: windowSize.width)
                withAnimation(chromeAnimation) {
                    if side != .center {
                        tuckY = PillTuck.fraction(y: y, height: windowSize.height)
                        tuck = side
                    }
                    pillDrag = .zero
                }
            }
    }

    private static func isDrag(_ t: CGSize) -> Bool { abs(t.width) > 4 || abs(t.height) > 4 }

    /// Bottom padding plus half the pill's height.
    private static let pillCenterFromBottom: CGFloat = 34

    private var tabDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard Self.isDrag(value.translation) else { return }
                let start = PillTuck.tabY(fraction: tuckY, height: windowSize.height)
                tabDragY = PillTuck.tabY(fraction: Double((start + value.translation.height) / max(windowSize.height, 1)),
                                         height: windowSize.height)
            }
            .onEnded { value in
                guard Self.isDrag(value.translation) else { setTuck(.center); return }
                let start = PillTuck.tabY(fraction: tuckY, height: windowSize.height)
                let inward = tuck == .left ? value.translation.width : -value.translation.width
                withAnimation(chromeAnimation) {
                    if inward > PillTuck.pullOut {
                        tuck = .center
                    } else {
                        tuckY = PillTuck.fraction(y: start + value.translation.height, height: windowSize.height)
                    }
                    tabDragY = nil
                }
            }
    }

    private func setTuck(_ side: PillTuck) {
        withAnimation(chromeAnimation) { tuck = side }
    }

    /// In "I'll name them", a marker dropped while Recaptr is the active
    /// app opens a title field. Never from inside another app.
    private func askForMarkerTitle(_ index: Int) {
        guard vm.markerNaming == .manual, NSApp.isActive,
              SelfCapture.mainWindow?.isKeyWindow == true else { return }
        withAnimation(chromeAnimation) { titlingMarker = index }
    }

    /// Typed straight into the view model, so stopping mid-word keeps it.
    private func markerTitleBinding(_ index: Int) -> Binding<String> {
        Binding(get: { vm.markerTitles[index] ?? "" },
                set: { vm.markerTitles[index] = $0 })
    }

    /// Capturing the display this window is on.
    private var capturesOwnScreen: Bool {
        guard let src = vm.selectedMainSource, src.kind == .screenDisplay else { return false }
        return src.displayID != nil && src.displayID == windowDisplay
    }

    private var chromeAnimation: Animation {
        Motion.pick(Motion.liquid, reduceMotion: reduceMotion)
    }

    private func setChrome(shown: Bool) {
        guard chromeShown != shown else { return }
        withAnimation(chromeAnimation) { chromeShown = shown }
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
                .frame(width: Spacing.topRow, height: Spacing.topRow)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .recaptrGlass(in: Circle(), interactive: true)
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
                .frame(width: Spacing.topRow, height: Spacing.topRow)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .recaptrGlass(in: Circle(), interactive: true)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settingsButton")
    }

    // MARK: - No-source hint

    private var noSourceHint: some View {
        VStack(spacing: 10) {
            Wordmark(height: 26)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
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
        setChrome(shown: true)
        scheduleFade()
    }

    private func scheduleFade() {
        guard vm.selectedMainSource != nil else { return }
        // The after-take card keeps the controls up until it's closed.
        guard !debugKeepsChrome, vm.presentedTake == nil else { return }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(fadeDelay))
            guard !Task.isCancelled else { return }
            setChrome(shown: false)
        }
    }

    /// Chrome stays visible while no source is selected.
    private func resetFadeIfNeeded() {
        if vm.selectedMainSource == nil {
            fadeTask?.cancel()
            setChrome(shown: true)
        } else {
            scheduleFade()
        }
    }

    // MARK: - Mode <-> Source plumbing

    private var activeModeBinding: Binding<SourceMode> {
        Binding(
            get: { activeMode },
            set: { newMode in
                guard !vm.isRecording else { return }
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
                guard !vm.isRecording else { return }
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
            if TestHooks.isOn, d.bool(forKey: "RecaptrUITestHoldMarkerFlash") {
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

    /// "Pick another source" opens the sidebar; the rest the view model runs.
    private func handleFix(_ fix: Notice.Fix) {
        if fix == .pickSource {
            sidebarVisible = true
            vm.notice = nil
        } else {
            vm.perform(fix)
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
        if TestHooks.isOn {
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

    /// Hidden buttons for the window-only shortcuts. Record, marker and
    /// sources live in the Recording menu. Each needs its own Button; a
    /// ForEach doesn't attach the shortcuts reliably.
    private var shortcutCarrier: some View {
        Group {
            Button("") { vm.monitorEnabled.toggle() }
                .keyboardShortcut("k", modifiers: [.command])
            Button("") { Task { await vm.saveReplay() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("") { sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        .hidden()
        .accessibilityHidden(true)
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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("RecaptrSidebarVisible") private var sidebarVisible = false
    @AppStorage(WelcomeSheet.seenKey) private var welcomeSeen = false
    @AppStorage(WhatsNewSheet.seenKey) private var whatsNewSeen = ""
    /// `-RecaptrUITestShowWelcome YES` / `-RecaptrUITestShowWhatsNew YES` show
    /// the sheets in UI tests, which otherwise skip them.
    @State private var testSheet = TestHooks.isOn
        ? (UserDefaults.standard.bool(forKey: "RecaptrUITestShowWelcome") ? "welcome"
           : UserDefaults.standard.bool(forKey: "RecaptrUITestShowWhatsNew") ? "whatsNew" : "")
        : ""

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
            get: { TestHooks.isOn ? testSheet == "welcome" : !welcomeSeen },
            set: { shown in
                guard !shown else { return }
                // However it closed, finish like Skip so the preview never stays held.
                if TestHooks.isOn { testSheet = "" } else {
                    UserDefaults.standard.set(WhatsNewSheet.version, forKey: WhatsNewSheet.seenKey)
                    welcomeSeen = true
                }
                vm.finishOnboarding()
            }
        )) {
            WelcomeSheet()
                .environmentObject(vm)
                .interactiveDismissDisabled()
        }
        // Coming from 1.0: what changed, instead of the whole onboarding.
        .background {
            Color.clear.sheet(isPresented: Binding(
                get: { TestHooks.isOn ? testSheet == "whatsNew" : (welcomeSeen && whatsNewSeen != WhatsNewSheet.version) },
                set: { if !$0 { if TestHooks.isOn { testSheet = "" } else { whatsNewSeen = WhatsNewSheet.version } } }
            )) {
                WhatsNewSheet()
                    .environmentObject(vm)
            }
        }
        .onAppear {
            // UI tests start with the sidebar closed. Not a launch
            // argument: that would pin the value and break toggling.
            if TestHooks.isOn {
                sidebarVisible = false
            }
            let open = openWindow
            vm.openMainWindow = { open(id: MainViewModel.mainWindowID) }
        }
    }
}

extension EnvironmentValues {
    /// Whether the floating chrome is showing. Live meters pause when it isn't.
    @Entry var chromeVisible: Bool = true
}
