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
