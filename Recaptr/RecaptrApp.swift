//
//  RecaptrApp.swift
//  Recaptr
//

import SwiftUI

@main
struct RecaptrApp: App {

    @StateObject private var vm = MainViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #if DEBUG
    @AppStorage(GlassTest.key) private var glassTest = GlassTest.standard
    @AppStorage(GlassTest.keepChromeKey) private var keepChromeVisible = false
    #endif

    var body: some Scene {
        WindowGroup {
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
            CommandMenu("Recording") {
                RecordingCommands(vm: vm)
            }
            // No help book, so the welcome sheet takes Help's place.
            CommandGroup(replacing: .help) {
                Button("Welcome to Recaptr") {
                    UserDefaults.standard.set(false, forKey: WelcomeSheet.seenKey)
                }
            }
            #if DEBUG
            CommandMenu("Debug") {
                Button("Size Window for Store Screenshots") { StoreScreenshot.sizeWindow() }
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

        Settings {
            SettingsView()
                .environmentObject(vm)
        }

        // Shown only while recording. The setter is ignored so hiding the
        // menu bar item can't stop the recording.
        MenuBarExtra(isInserted: Binding(
            get: { vm.isRecording },
            set: { _ in }
        )) {
            MenuBarContent().environmentObject(vm)
        } label: {
            MenuBarLabel(clock: vm.clock)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Lets the view model stop and save a take before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: MainViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewModel?.replyToQuit() ?? .terminateNow
    }
}
