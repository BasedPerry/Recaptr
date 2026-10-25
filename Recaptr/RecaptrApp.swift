//
//  RecaptrApp.swift
//  Recaptr
//

import SwiftUI

@main
struct RecaptrApp: App {

    @StateObject private var vm = MainViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(MenuBarContent.alwaysKey, store: TestHooks.preferences) private var menuBarAlways = false
    #if DEBUG
    @AppStorage(GlassTest.key) private var glassTest = GlassTest.standard
    @AppStorage(GlassTest.keepChromeKey) private var keepChromeVisible = false
    #endif

    var body: some Scene {
        WindowGroup(id: MainViewModel.mainWindowID) {
            RecaptrRootView()
                .environmentObject(vm)
                .onAppear { appDelegate.viewModel = vm }
                .onOpenURL { vm.handle(url: $0) }
                // recaptr:// goes to this window instead of opening another.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        // The preview runs under the traffic lights; keep that corner free of chrome.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // One window only: a second would take over the single preview.
            CommandGroup(replacing: .newItem) {
                RecentRecordingsMenu(vm: vm, recent: vm.recentTakes)
            }
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandMenu("Recording") {
                RecordingCommands(vm: vm)
            }
            // No help book, so the welcome sheet takes Help's place.
            CommandGroup(replacing: .help) {
                Button("Welcome to Recaptr") {
                    UserDefaults.standard.set(false, forKey: WelcomeSheet.seenKey)
                }
                .disabled(vm.isRecording)
            }
            #if DEBUG
            CommandMenu("Debug") {
                Button("Size Window for Store Screenshots") { StoreScreenshot.sizeWindow() }
                Button("Size Window for Video (1920×1080)") { StoreScreenshot.sizeWindowForVideo() }
                Button("Capture Store Screenshot") {
                    Task {
                        do {
                            let url = try await StoreScreenshot.capture(into: vm.recordingStorage.resolveSaveDirectory())
                            vm.status = "Store screenshot saved: \(url.lastPathComponent)"
                            print("RecaptrStoreScreenshot: \(url.path)")
                        } catch {
                            vm.status = "Store screenshot failed: \(error.localizedDescription)"
                        }
                    }
                }
                .keyboardShortcut("p", modifiers: [.control, .option, .command])
                Divider()
                Toggle("Keep Controls Visible", isOn: $keepChromeVisible)
                Picker("Glass Test", selection: $glassTest) {
                    ForEach(GlassTest.allCases) { Text($0.title).tag($0) }
                }
            }
            #endif
        }

        Window("About Recaptr", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(vm)
        }

        // Shown while recording, or always when that's turned on. The
        // setter is ignored so hiding the item can't stop a recording.
        MenuBarExtra(isInserted: Binding(
            get: { vm.isRecording || menuBarAlways },
            set: { _ in }
        )) {
            MenuBarContent().environmentObject(vm)
        } label: {
            MenuBarLabel(clock: vm.clock, isRecording: vm.isRecording)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Lets the view model stop and save a take before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: MainViewModel?
    private var windowCloseObserver: NSObjectProtocol?
    /// A quit is under way; windows closing during it don't start another.
    private var quitStarted = false

    /// Closing the capture window quits, even with Settings or About open,
    /// so the capture card isn't held with nothing on screen. Mid-take the
    /// take keeps going; stopping it brings the window back.
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window.identifier?.rawValue.hasPrefix(MainViewModel.mainWindowID) == true else { return }
            MainActor.assumeIsolated {
                guard !self.quitStarted, !(self.viewModel?.isRecording ?? false) else { return }
                // After the close finishes.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(viewModel?.isRecording ?? false)
    }

    /// A Dock click brings the capture window back if it was closed mid-take.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MainViewModel.mainWindow == nil {
            viewModel?.openMainWindow?()
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = viewModel?.replyToQuit() ?? .terminateNow
        quitStarted = reply != .terminateCancel
        return reply
    }
}
