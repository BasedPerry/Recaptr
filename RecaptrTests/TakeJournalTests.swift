//
//  TakeJournalTests.swift
//  RecaptrTests
//

import Testing
import Foundation
@testable import Recaptr

struct TakeJournalTests {

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakeJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeTake(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension("mov")
        try Data([0]).write(to: url)
        return url
    }

    @Test func journalIsHiddenBesideTheTake() {
        let mov = URL(fileURLWithPath: "/Volumes/Drive/Recaptr_2026-10-18T23-21-36Z.mov")
        let journal = TakeJournal.url(for: mov)
        #expect(journal.lastPathComponent == ".Recaptr_2026-10-18T23-21-36Z.recaptr-take")
        #expect(journal.deletingLastPathComponent() == mov.deletingLastPathComponent())
    }

    @Test func savesAndLoads() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mov = try makeTake("Recaptr_A", in: folder)
        let journal = TakeJournal(series: "PS5 stuff", episode: "", markerSeconds: [12.5, 40])
        try journal.save(for: mov)
        #expect(TakeJournal.load(for: mov) == journal)
        TakeJournal.remove(for: mov)
        #expect(TakeJournal.load(for: mov) == nil)
    }

    @Test func findsLeftoverTakes() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try makeTake("Recaptr_A", in: folder)
        let second = try makeTake("Recaptr_B", in: folder)
        try TakeJournal(series: "", episode: "", markerSeconds: [1]).save(for: first)
        try TakeJournal(series: "Dual-PC", episode: "Ep 9", markerSeconds: []).save(for: second)
        _ = try makeTake("Finished take", in: folder)

        let found = TakeJournal.leftovers(in: folder)
        #expect(found.map { $0.movURL.lastPathComponent } == ["Recaptr_A.mov", "Recaptr_B.mov"])
        #expect(found[1].journal.series == "Dual-PC")
    }

    @Test func skipsTheTakeRecordingNow() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = try makeTake("Recaptr_A", in: folder)
        try TakeJournal(series: "", episode: "", markerSeconds: []).save(for: recording)
        #expect(TakeJournal.leftovers(in: folder, excluding: recording).isEmpty)
        #expect(TakeJournal.load(for: recording) != nil)
    }

    @Test func dropsJournalsWhoseTakeIsGone() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mov = try makeTake("Recaptr_A", in: folder)
        try TakeJournal(series: "", episode: "", markerSeconds: [3]).save(for: mov)
        try FileManager.default.removeItem(at: mov)

        #expect(TakeJournal.leftovers(in: folder).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: TakeJournal.url(for: mov).path))
    }
}
