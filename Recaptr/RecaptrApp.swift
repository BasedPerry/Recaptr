//
//  RecaptrApp.swift
//  Recaptr
//

import SwiftUI

@main
struct RecaptrApp: App {

    @StateObject private var vm = MainViewModel()

    var body: some Scene {
        WindowGroup {
            RecaptrRootView()
                .environmentObject(vm)
        }
        // The preview runs under the traffic lights; keep that corner free of chrome.
        .windowStyle(.hiddenTitleBar)
        .commands {
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
