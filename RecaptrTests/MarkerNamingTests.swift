//
//  MarkerNamingTests.swift
//  RecaptrTests
//

import Testing
import Foundation
@testable import Recaptr

struct MarkerNamingTests {

    /// A throwaway defaults domain, never the app's real settings.
    private func defaults() -> UserDefaults {
        let name = "RecaptrTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func freshInstallHasNoChoice() {
        #expect(MarkerNaming.stored(in: defaults()) == nil)
    }

    @Test func oneOhToggleOnMigratesToAppleIntelligence() {
        let d = defaults()
        d.set(true, forKey: MarkerNaming.legacyKey)
        #expect(MarkerNaming.stored(in: d) == .appleIntelligence)
    }

    @Test func oneOhToggleOffMigratesToNumbered() {
        let d = defaults()
        d.set(false, forKey: MarkerNaming.legacyKey)
        #expect(MarkerNaming.stored(in: d) == .numbered)
    }

    @Test func savedChoiceWinsOverTheOldToggle() {
        let d = defaults()
        d.set(true, forKey: MarkerNaming.legacyKey)
        d.set(MarkerNaming.manual.rawValue, forKey: MarkerNaming.storageKey)
        #expect(MarkerNaming.stored(in: d) == .manual)
    }

    @Test func onlyAppleIntelligenceRunsTheModel() {
        #expect(MarkerNaming.usesAI(.appleIntelligence, available: true))
        #expect(!MarkerNaming.usesAI(.appleIntelligence, available: false))
        #expect(!MarkerNaming.usesAI(.manual, available: true))
        #expect(!MarkerNaming.usesAI(.numbered, available: true))
        // Unpicked keeps the 1.0 default until onboarding asks.
        #expect(MarkerNaming.usesAI(nil, available: true))
    }
}
