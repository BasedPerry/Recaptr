//
//  MainViewModel+Actions.swift
//  Recaptr
//
//  Runs `RecaptrAction`s, whatever triggered them, and keeps the global
//  keys registered.
//

import AppKit

extension MainViewModel {

    func perform(_ action: RecaptrAction) {
        switch action {
        case .toggleRecording:
            Task { isRecording ? await stopRecording() : await startRecordingFromAction() }
        case .startRecording:
            Task { if !isRecording { await startRecordingFromAction() } }
        case .stopRecording:
            Task { await stopRecording() }
        case .dropMarker:
            dropMarker()
        case .sourceCaptureCard:
            selectSource(.camera)
        case .sourceScreen:
            selectSource(.screen)
        case .sourceWindow:
            selectSource(.window)
        case .toggleGameMonitor:
            gameMonitorEnabled.toggle()
        case .toggleMicMonitor:
            micMonitorEnabled.toggle()
        case .toggleWindow:
            toggleWindow()
        case .openLastTake:
            openLastTake()
        }
    }

    /// Runs the action a recaptr:// URL names. False when the URL isn't an
    /// action or other apps aren't allowed to control Recaptr.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard allowsExternalControl, let action = RecaptrAction(url: url) else { return false }
        perform(action)
        return true
    }

    /// Records with the current source and settings, exactly as the window
    /// shows them. Starts the preview first if it's off.
    private func startRecordingFromAction() async {
        // The first recording may ask for a save folder; that needs the window.
        if recordingStorage.needsFolderChoice { bringForward() }
        if !isPreviewing { await startPreview() }
        await startRecording()
    }

    /// Same as ⌘1–3: switches mode and picks its first source. Ignored while
    /// recording, like the switcher.
    func selectSource(_ mode: SourceMode) {
        guard !isRecording else { return }
        if mode != .camera { screenModeSelected() }
        if let first = catalog.videoSources.first(where: { $0.kind == mode.sourceKind }) {
            selectedMainSource = first
        }
    }

    func toggleWindow() {
        let window = NSApp.windows.first { $0.canBecomeMain }
        if NSApp.isActive, window?.isVisible == true, window?.isMiniaturized == false {
            NSApp.hide(nil)
        } else {
            bringForward()
        }
    }

    /// The last take (this session, or the newest recent one) in the
    /// after-take card.
    func openLastTake() {
        recentTakes.prune()
        guard let take = lastTake ?? recentTakes.urls.first.map(Take.load) else { return }
        presentedTake = take
        bringForward()
    }

    func bringForward() {
        NSApp.unhide(nil)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Global keys

    /// Registers the keys that apply right now. The marker key is only live
    /// while recording. UI test copies only take the marker key, so they
    /// don't grab keys from a real copy running alongside.
    func refreshGlobalHotKeys() {
        var wanted = hotKeySettings.all.filter { !$0.key.hotKeyOnlyWhileRecording || isRecording }
        if Self.isUITesting { wanted = wanted.filter { $0.key == .dropMarker } }
        hotKeysTakenElsewhere = globalHotKeys.update(wanted)
    }

    /// Sets or clears an action's global key. Keeps the old key and returns
    /// why when the new one can't be used.
    @discardableResult
    func setHotKey(_ binding: HotKeyBinding?, for action: RecaptrAction) -> HotKeySettings.Problem? {
        let previous = hotKeySettings
        var updated = hotKeySettings
        if let problem = updated.set(binding, for: action) { return problem }
        hotKeySettings = updated
        refreshGlobalHotKeys()
        // Only a live key can be found taken; the marker key is checked when recording starts.
        if binding != nil, hotKeysTakenElsewhere.contains(action) {
            hotKeySettings = previous
            refreshGlobalHotKeys()
            return .takenElsewhere
        }
        if !Self.isUITesting { hotKeySettings.save() }
        return nil
    }

    func restoreDefaultHotKeys() {
        hotKeySettings.restoreDefaults()
        if !Self.isUITesting { hotKeySettings.save() }
        refreshGlobalHotKeys()
    }

    /// The key to show next to an action, for menus and tooltips.
    func hotKeyLabel(for action: RecaptrAction) -> String? {
        hotKeySettings.binding(for: action)?.display
    }
}

// MARK: - Notices

extension MainViewModel {

    /// Shows a notice in the window, and as a notification when a take
    /// ended early while Recaptr was in the background.
    func show(_ notice: Notice) {
        self.notice = notice
        if !NSApp.isActive { NoticeNotifier.post(notice) }
    }

    /// Runs a notice's fix button. Picking a source is up to the window.
    func perform(_ fix: Notice.Fix) {
        switch fix {
        case .openScreenRecordingSettings: openScreenCapturePrivacyPane()
        case .openMicrophoneSettings:      openMicrophonePrivacyPane()
        case .openCameraSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        case .pickSaveFolder:              recordingStorage.pickFolder()
        case .pickSource:                  break
        }
        notice = nil
    }
}
