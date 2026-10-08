//
//  ActionTests.swift
//  RecaptrTests
//

import Testing
import Foundation
import Carbon.HIToolbox
@testable import Recaptr

struct RecaptrActionURLTests {

    @Test func everyActionRoundTripsThroughItsURL() {
        for action in RecaptrAction.allCases {
            #expect(RecaptrAction(url: action.url) == action)
        }
    }

    @Test func pathsAreUnique() {
        #expect(Set(RecaptrAction.allCases.map(\.urlPath)).count == RecaptrAction.allCases.count)
    }

    @Test func parsesTheDocumentedForms() {
        #expect(RecaptrAction(url: URL(string: "recaptr://record/toggle")!) == .toggleRecording)
        #expect(RecaptrAction(url: URL(string: "RECAPTR://Marker")!) == .dropMarker)
        #expect(RecaptrAction(url: URL(string: "recaptr://source/screen/")!) == .sourceScreen)
        #expect(RecaptrAction(url: URL(string: "recaptr:///marker")!) == .dropMarker)
    }

    /// Only listed actions: nothing that changes settings or touches files.
    @Test func rejectsAnythingElse() {
        #expect(RecaptrAction(url: URL(string: "recaptr://settings/save-folder?path=/tmp")!) == nil)
        #expect(RecaptrAction(url: URL(string: "recaptr://")!) == nil)
        #expect(RecaptrAction(url: URL(string: "https://record/toggle")!) == nil)
        #expect(RecaptrAction(url: URL(string: "recaptr://record")!) == nil)
    }
}

struct HotKeyTests {

    private let r = HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: HotKeyBinding.controlOptionCommand)
    private let b = HotKeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: HotKeyBinding.controlOptionCommand)
    private let m = HotKeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey))

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "RecaptrTests.\(UUID().uuidString)")!
    }

    @Test func shipsRecordAndMarkerOnly() {
        let s = HotKeySettings()
        #expect(s.binding(for: .toggleRecording) == r)
        #expect(s.binding(for: .dropMarker) == b)
        #expect(s.all.count == 2)
    }

    @Test func displaysInStandardOrder() {
        #expect(r.display == "⌃⌥⌘R")
        let all = HotKeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.display == "⌃⌥⇧⌘F5")
    }

    @Test func needsARealModifier() {
        var s = HotKeySettings()
        let shiftOnly = HotKeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(shiftKey))
        #expect(s.set(shiftOnly, for: .dropMarker) == .needsModifier)
        #expect(s.binding(for: .dropMarker) == b)
    }

    @Test func refusesAComboAnotherActionUses() {
        var s = HotKeySettings()
        #expect(s.set(r, for: .dropMarker) == .usedBy(.toggleRecording))
        #expect(s.binding(for: .dropMarker) == b)
    }

    @Test func clearedStaysClearedAndSurvivesSaving() {
        let d = defaults()
        var s = HotKeySettings()
        s.set(nil, for: .toggleRecording)
        s.set(m, for: .sourceScreen)
        s.save(to: d)
        let loaded = HotKeySettings.load(from: d)
        #expect(loaded.binding(for: .toggleRecording) == nil)
        #expect(loaded.binding(for: .sourceScreen) == m)
        #expect(loaded.binding(for: .dropMarker) == b)
        #expect(loaded == s)
    }

    @Test func restoreDefaultsUndoesEverything() {
        var s = HotKeySettings()
        s.set(nil, for: .toggleRecording)
        s.set(m, for: .toggleWindow)
        s.restoreDefaults()
        #expect(s == HotKeySettings())
    }

    /// A freed combo can move to another action.
    @Test func comboCanMoveAfterBeingCleared() {
        var s = HotKeySettings()
        s.set(nil, for: .toggleRecording)
        #expect(s.set(r, for: .startRecording) == nil)
        #expect(s.binding(for: .startRecording) == r)
    }

    @Test func ignoresJunkInStorage() {
        let d = defaults()
        d.set(["dropMarker": "nonsense", "notAnAction": "15:4352", "sourceWindow": "46:512"], forKey: HotKeySettings.storageKey)
        let s = HotKeySettings.load(from: d)
        #expect(s.binding(for: .dropMarker) == b)
        // Shift-only from storage is rejected too.
        #expect(s.binding(for: .sourceWindow) == nil)
    }
}
