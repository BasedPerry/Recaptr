//
//  Motion.swift
//  Recaptr
//
//  The app's few animation curves. Glass reshapes with `liquid`; small
//  state changes use the others. Reduce Motion swaps all of them for a
//  short cross-fade.
//

import SwiftUI

enum Motion {
    /// Glass changing shape: the bar flowing into the recording pill,
    /// chrome showing and hiding, the sidebar opening.
    static let liquid = Animation.spring(duration: 0.6, bounce: 0.22)
    /// A selection moving or a control switching state.
    static let snappy = Animation.spring(duration: 0.3, bounce: 0.2)
    /// Something small arriving: a marker count, the record button's shape.
    static let pop = Animation.spring(duration: 0.28, bounce: 0.35)
    /// Color and tint changes.
    static let fade = Animation.easeInOut(duration: 0.25)
    /// Every curve under Reduce Motion.
    static let reduced = Animation.easeInOut(duration: 0.15)

    static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}
