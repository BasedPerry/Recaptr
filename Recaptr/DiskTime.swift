//
//  DiskTime.swift
//  Recaptr
//
//  How long the save drive lasts at the current preset and size.
//

import Foundation

nonisolated struct DiskTime: Equatable, Sendable {

    enum Level: Equatable, Sendable {
        case fine, low, critical
    }

    /// Seconds of recording that fit, after the space Recaptr keeps free.
    let seconds: TimeInterval

    /// Under 30 minutes is low, under 10 critical.
    var level: Level {
        seconds < 10 * 60 ? .critical : seconds < 30 * 60 ? .low : .fine
    }

    /// "About 3 h 10 m left", "About 25 m left", "Under a minute left".
    var label: String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Under a minute left" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "About \(m) m left" }
        return m == 0 ? "About \(h) h left" : "About \(h) h \(m) m left"
    }

    /// Recording time for `freeBytes` at `bitsPerSecond` video plus audio.
    /// The last `reserveBytes` don't count: recording stops itself there.
    static func estimate(freeBytes: Int64, bitsPerSecond: Int, audioTracks: Int = 1,
                         reserveBytes: Int64 = 1_000_000_000) -> DiskTime {
        // AAC at 128 kbps per track (Recorder's setting), plus ~2% container overhead.
        let audio = 128_000 * max(audioTracks, 0)
        let bytesPerSecond = Double(bitsPerSecond + audio) / 8 * 1.02
        let usable = Double(max(freeBytes - reserveBytes, 0))
        return DiskTime(seconds: bytesPerSecond > 0 ? usable / bytesPerSecond : 0)
    }

    /// Free space on the volume holding `folder`, or nil when it doesn't say
    /// (some network mounts).
    static func freeBytes(at folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
