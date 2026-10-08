//
//  DiskTimeTests.swift
//  RecaptrTests
//

import Testing
import Foundation
@testable import Recaptr

struct DiskTimeTests {

    /// Standard 1080p60 (20 Mbps + one AAC track) is about 9 GB an hour.
    @Test func standardTenEightyIsAboutNineGigabytesAnHour() {
        let bps = VideoQuality.standard.bitrate(width: 1920, height: 1080)
        let hour = DiskTime.estimate(freeBytes: 10_000_000_000, bitsPerSecond: bps, reserveBytes: 0)
        // 10 GB lasts a bit over an hour.
        #expect(hour.seconds > 3600 && hour.seconds < 4400)
    }

    @Test func reserveIsNotCounted() {
        let t = DiskTime.estimate(freeBytes: 900_000_000, bitsPerSecond: 20_000_000)
        #expect(t.seconds == 0)
        #expect(t.label == "Under a minute left")
        #expect(t.level == .critical)
    }

    @Test func labelsAndLevels() {
        #expect(DiskTime(seconds: 3 * 3600 + 10 * 60 + 40).label == "About 3 h 10 m left")
        #expect(DiskTime(seconds: 2 * 3600).label == "About 2 h left")
        #expect(DiskTime(seconds: 25 * 60).label == "About 25 m left")
        #expect(DiskTime(seconds: 31 * 60).level == .fine)
        #expect(DiskTime(seconds: 29 * 60).level == .low)
        #expect(DiskTime(seconds: 9 * 60).level == .critical)
    }

    /// More audio tracks means less time.
    @Test func audioTracksCount() {
        let one = DiskTime.estimate(freeBytes: 50_000_000_000, bitsPerSecond: 20_000_000, audioTracks: 1)
        let three = DiskTime.estimate(freeBytes: 50_000_000_000, bitsPerSecond: 20_000_000, audioTracks: 3)
        #expect(three.seconds < one.seconds)
    }
}
