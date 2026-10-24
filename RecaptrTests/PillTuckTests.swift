//
//  PillTuckTests.swift
//  RecaptrTests
//

import Testing
import Foundation
@testable import Recaptr

struct PillTuckTests {

    @Test func dropNearAnEdgeTucks() {
        #expect(PillTuck.landing(x: 40, width: 1200) == .left)
        #expect(PillTuck.landing(x: 1180, width: 1200) == .right)
        #expect(PillTuck.landing(x: 600, width: 1200) == .center)
        // Just outside the zone stays in the middle.
        #expect(PillTuck.landing(x: PillTuck.edgeZone + 1, width: 1200) == .center)
    }

    @Test func flickPastTheEdgeTucks() {
        #expect(PillTuck.landing(x: -300, width: 1200) == .left)
        #expect(PillTuck.landing(x: 1900, width: 1200) == .right)
    }

    @Test func tabStaysClearOfTheChrome() {
        #expect(PillTuck.tabY(fraction: 0, height: 800) == PillTuck.topInset)
        #expect(PillTuck.tabY(fraction: 1, height: 800) == 800 - PillTuck.bottomInset)
        #expect(PillTuck.tabY(fraction: 0.5, height: 800) == 400)
    }

    @Test func storedFractionRoundTrips() {
        let f = PillTuck.fraction(y: 300, height: 800)
        #expect(PillTuck.tabY(fraction: f, height: 800) == 300)
        // A drop on top of the bar is pulled up out of its way.
        let low = PillTuck.fraction(y: 790, height: 800)
        #expect(PillTuck.tabY(fraction: low, height: 800) == 800 - PillTuck.bottomInset)
        #expect(PillTuck.fraction(y: 100, height: 0) == 0.5)
    }
}
