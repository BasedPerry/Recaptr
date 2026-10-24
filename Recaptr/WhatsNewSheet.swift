//
//  WhatsNewSheet.swift
//  Recaptr
//
//  Shown once to people coming from 1.0 instead of the whole onboarding:
//  what changed, and the marker-naming choice, pre-filled from their
//  1.0 setting so they only confirm it.
//

import SwiftUI

struct WhatsNewSheet: View {
    static let seenKey = "RecaptrWhatsNewSeen"
    static let version = "1.1"

    @EnvironmentObject var vm: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(height: 24)
                Text("What's new in 1.1")
                    .font(.title2.bold())
            }
            VStack(alignment: .leading, spacing: 12) {
                item("rectangle.bottomthird.inset.filled", "One bar for everything",
                     "Game and mic levels, headphones, record and time live in the bar at the bottom. Mid-take it shrinks to a pill you can tuck against the edge.")
                item("film.stack", "A card after every take",
                     "See your markers with thumbnails, open the take in Final Cut, and rename it, series included. File → Recent Recordings brings back older takes.")
                item("keyboard", "Keys that work from any app", keysText)
            }
            Divider()
            Text("How should markers be named?").font(.headline)
            NamingChoices()
            HStack {
                Spacer()
                Button("Continue") {
                    // Saves the pre-filled choice too.
                    vm.markerNaming = vm.markerNaming
                    if !TestHooks.isOn { UserDefaults.standard.set(Self.version, forKey: Self.seenKey) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.markerNaming == nil)
                .accessibilityIdentifier("whatsNewDone")
            }
        }
        .padding(28)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // 1.0 named markers with Apple Intelligence when the Mac could.
            if vm.markerNaming == nil {
                vm.markerNaming = MarkerNamer.isAvailable ? .appleIntelligence : .numbered
            }
        }
        .accessibilityIdentifier("whatsNewSheet")
    }

    private var keysText: String {
        var parts: [String] = []
        if let key = vm.hotKeyLabel(for: .toggleRecording) { parts.append("\(key) records") }
        if let key = vm.hotKeyLabel(for: .dropMarker) { parts.append("\(key) drops a marker") }
        let lead = parts.isEmpty ? "Give any action a key" : parts.joined(separator: " and ") + " from inside your game"
        return lead + ". Set your own in Settings → Shortcuts."
    }

    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
