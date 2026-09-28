//
//  RecordingClock.swift
//  Recaptr
//
//  Per-second recording readouts, kept out of MainViewModel so a tick
//  only redraws the views that show them.
//

import Combine
import Foundation

final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var bytes: Int64 = 0
    /// True once the first frame has started the file.
    @Published var anchored = false

    /// "mm:ss", or "h:mm:ss" past an hour.
    var formattedElapsed: String {
        let t = Int(elapsed)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
