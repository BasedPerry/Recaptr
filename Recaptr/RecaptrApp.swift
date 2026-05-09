//
//  RecaptrApp.swift
//  Recaptr
//
//  Created by bp on 1/28/26.
//

import SwiftUI

@main
struct RecaptrApp: App {

    // Phase 2 (2026-05-09): swapped @StateObject DeviceCatalog for
    // @StateObject MainViewModel. The catalog now lives inside
    // MainViewModel (single source of truth), and MainViewModel
    // triggers `await catalog.refresh()` from its own init — so the
    // .task modifier on the root view is no longer needed here.
    @StateObject private var vm = MainViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
    }
}
