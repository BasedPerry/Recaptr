//
//  TestHooks.swift
//  Recaptr
//
//  UI-test switches passed as launch arguments (`-RecaptrUITesting YES`
//  and the `-RecaptrUITest…` flags). Debug builds only: in Release they're
//  always off and the code behind them compiles away, so no hidden or
//  dormant feature ships (App Review 2.3.1).
//

import Foundation

nonisolated enum TestHooks {
    /// True when the UI tests launched this copy.
    static var isOn: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "RecaptrUITesting")
        #else
        false
        #endif
    }

    /// Where window preferences (pill tuck, menu bar, hide while
    /// recording) are kept. Test copies get a store of their own, emptied
    /// at launch, so they never change the user's.
    static let preferences: UserDefaults = {
        #if DEBUG
        if isOn, let store = UserDefaults(suiteName: "RecaptrUITestPreferences") {
            store.removePersistentDomain(forName: "RecaptrUITestPreferences")
            return store
        }
        #endif
        return .standard
    }()
}
