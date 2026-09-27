//
//  RecordingClock.swift
//  Recaptr
//
//  The readouts that change every second while recording (elapsed
//  time, file size, whether the first frame has anchored the file).
//  Kept apart from MainViewModel so a tick only updates the views that
//  show them, not every view observing the view model.
//

import Combine
import Foundation

final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var bytes: Int64 = 0
    /// The writer has started its file (first frame arrived).
    @Published var anchored = false

    /// "mm:ss", or "h:mm:ss" past an hour.
    var formattedElapsed: String {
        let t = Int(elapsed)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
