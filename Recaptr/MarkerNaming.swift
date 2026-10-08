//
//  MarkerNaming.swift
//  Recaptr
//
//  How markers and blank episodes get their names after a take.
//

import Foundation

nonisolated enum MarkerNaming: String, CaseIterable, Identifiable, Sendable {
    /// Named on-device from the frames and commentary.
    case appleIntelligence
    /// Numbered, then the after-take card asks for names.
    case manual
    /// Numbered, no prompt.
    case numbered

    var id: Self { self }

    var label: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .manual:            return "I'll name them"
        case .numbered:          return "Just number them"
        }
    }

    var detail: String {
        switch self {
        case .appleIntelligence: return "Named from the picture and what you said, after you stop. Runs on your Mac."
        case .manual:            return "Numbered while you record. Type names when the take ends."
        case .numbered:          return "Marker 1, Marker 2, and so on. No AI runs."
        }
    }

    static let storageKey = "RecaptrMarkerNaming"
    /// The 1.0 on/off setting, read once to migrate.
    static let legacyKey = "RecaptrAINaming"

    /// The saved choice, or nil when nobody has picked yet. A 1.0 toggle
    /// maps to a choice so upgraders only confirm it.
    static func stored(in defaults: UserDefaults = .standard) -> MarkerNaming? {
        if let raw = defaults.string(forKey: storageKey), let mode = MarkerNaming(rawValue: raw) {
            return mode
        }
        return migrated(from: defaults)
    }

    /// The choice implied by the 1.0 toggle, if it was ever saved.
    static func migrated(from defaults: UserDefaults) -> MarkerNaming? {
        guard defaults.object(forKey: legacyKey) != nil else { return nil }
        return defaults.bool(forKey: legacyKey) ? .appleIntelligence : .numbered
    }

    /// True when Apple Intelligence should run for this choice. Unpicked
    /// keeps the 1.0 default until onboarding asks.
    static func usesAI(_ mode: MarkerNaming?, available: Bool) -> Bool {
        available && (mode ?? .appleIntelligence) == .appleIntelligence
    }
}
