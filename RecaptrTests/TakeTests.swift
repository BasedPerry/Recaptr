//
//  TakeTests.swift
//  RecaptrTests
//

import Testing
import Foundation
@testable import Recaptr

struct FinalCutReadBackTests {

    /// What the writer produces reads back to the same titles and frame times.
    @Test func roundTripsMarkersAndEvent() throws {
        let xml = FinalCutMarkers.document(
            movURL: URL(fileURLWithPath: "/tmp/Fire Emblem – Ep 2.mov"),
            markers: [("Boss <Phase 2> & \"Rage\"", 7.61), ("Marker 2", 15.0)],
            width: 1920, height: 1080, fps: 59.94, duration: 30, audioTracks: 2,
            eventName: "Fire Emblem")
        let contents = try #require(FinalCutMarkers.read(Data(xml.utf8)))
        #expect(contents.eventName == "Fire Emblem")
        #expect(contents.markers.map(\.title) == ["Boss <Phase 2> & \"Rage\"", "Marker 2"])
        // Snapped to 59.94 frames: within half a frame of the original.
        #expect(abs(contents.markers[0].seconds - 7.61) < 0.5 / 59.94)
        #expect(abs(contents.markers[1].seconds - 15.0) < 0.5 / 59.94)
    }

    @Test func parsesFcpxmlTimes() {
        #expect(FinalCutMarkers.seconds(fromTime: "0s") == 0)
        #expect(FinalCutMarkers.seconds(fromTime: "12s") == 12)
        #expect(FinalCutMarkers.seconds(fromTime: "900/60s") == 15)
        #expect(FinalCutMarkers.seconds(fromTime: "1001/0s") == nil)
        #expect(FinalCutMarkers.seconds(fromTime: "15") == nil)
    }

    @Test func rejectsOtherXML() {
        #expect(FinalCutMarkers.read(Data("<plist/>".utf8)) == nil)
        #expect(FinalCutMarkers.read(Data("not xml".utf8)) == nil)
    }
}

struct TakeTests {

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecaptrTakeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSidecar(for mov: URL, event: String?, markers: [(String, Double)]) throws {
        let xml = FinalCutMarkers.document(movURL: mov, markers: markers, width: 1920, height: 1080,
                                           fps: 60, duration: 60, audioTracks: 1, eventName: event ?? "Recaptr")
        try xml.write(to: Take.sidecar(for: mov), atomically: true, encoding: .utf8)
    }

    @Test func loadsSeriesAndMarkersFromTheSidecar() throws {
        let dir = try folder()
        let mov = dir.appendingPathComponent("Fire Emblem – Ep 3 – Chapter 5.mov")
        try writeSidecar(for: mov, event: "Fire Emblem", markers: [("Ambush", 10), ("Marker 2", 20)])
        let take = Take.load(mov)
        #expect(take.series == "Fire Emblem")
        #expect(take.episode == "Ep 3 – Chapter 5")
        #expect(take.markers.map(\.title) == ["Ambush", "Marker 2"])
    }

    /// The default event name isn't a series.
    @Test func takeWithoutSeriesKeepsItsWholeName() throws {
        let dir = try folder()
        let mov = dir.appendingPathComponent("Recaptr_2026-10-08.mov")
        try writeSidecar(for: mov, event: nil, markers: [("Marker 1", 5)])
        let take = Take.load(mov)
        #expect(take.series == "")
        #expect(take.episode == "Recaptr_2026-10-08")
    }

    @Test func noSidecarMeansNoMarkers() throws {
        let take = Take.load(try folder().appendingPathComponent("Loose.mov"))
        #expect(take.markers.isEmpty)
        #expect(take.series == "")
    }

    @Test func renameKeepsBlankTitlesAndBuildsTheName() {
        let take = Take(url: URL(fileURLWithPath: "/r/FE/FE – Ep 1.mov"), series: "FE",
                        markers: [.init(title: "Marker 1", seconds: 1), .init(title: "Marker 2", seconds: 2)])
        let renamed = take.renamed(episode: "Ep 1 – Boss", markerTitles: ["Boss Fight", "  "])
        #expect(renamed?.url.lastPathComponent == "FE – Ep 1 – Boss.mov")
        #expect(renamed?.markers.map(\.title) == ["Boss Fight", "Marker 2"])
        #expect(take.renamed(episode: "   ", markerTitles: []) == nil)
    }

    /// "Name (2)" stays put when only the markers change.
    @Test func numberedDuplicateKeepsItsName() {
        let take = Take(url: URL(fileURLWithPath: "/r/FE/FE – Ep 1 (2).mov"), series: "FE", markers: [])
        #expect(take.renamed(episode: "Ep 1", markerTitles: [])?.url == take.url)
    }

    /// Renaming on disk never overwrites another take.
    @Test func applyNeverOverwrites() async throws {
        let dir = try folder()
        let a = dir.appendingPathComponent("A.mov")
        let b = dir.appendingPathComponent("B.mov")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let take = Take(url: a, series: "", markers: [])
        let wanted = try #require(take.renamed(episode: "B", markerTitles: []))
        let saved = try await Take.apply(from: take, to: wanted)
        #expect(saved.url.lastPathComponent == "B (2).mov")
        #expect(try Data(contentsOf: b) == Data("b".utf8))
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }
}

@MainActor
struct RecentTakesTests {

    @Test func newestFirstNoDuplicatesCapped() {
        var list: [URL] = []
        for i in 0..<12 { list = RecentTakes.adding(URL(fileURLWithPath: "/r/\(i).mov"), to: list) }
        list = RecentTakes.adding(URL(fileURLWithPath: "/r/5.mov"), to: list)
        #expect(list.count == RecentTakes.limit)
        #expect(list.first?.lastPathComponent == "5.mov")
        #expect(list.filter { $0.lastPathComponent == "5.mov" }.count == 1)
    }

    @Test func pruneDropsMissingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecaptrRecent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let kept = dir.appendingPathComponent("kept.mov")
        try Data().write(to: kept)
        let recent = RecentTakes(defaults: UserDefaults(suiteName: "RecaptrTests.\(UUID().uuidString)")!, persists: false)
        recent.add(dir.appendingPathComponent("gone.mov"))
        recent.add(kept)
        recent.prune()
        #expect(recent.urls == [kept])
    }

    @Test func renameKeepsThePlace() {
        let recent = RecentTakes(defaults: UserDefaults(suiteName: "RecaptrTests.\(UUID().uuidString)")!, persists: false)
        let a = URL(fileURLWithPath: "/r/a.mov"), b = URL(fileURLWithPath: "/r/b.mov")
        recent.add(a)
        recent.add(b)
        recent.replace(a, with: URL(fileURLWithPath: "/r/a2.mov"))
        #expect(recent.urls.map(\.lastPathComponent) == ["b.mov", "a2.mov"])
    }
}
