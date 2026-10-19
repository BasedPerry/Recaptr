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
}
