//  SnapshotStalenessTests.swift
//  BarryTests
//
//  The complication's snapshot and the widget's entry both say "stale"
//  past two hours. Driven by a clock, not by waiting.

import Foundation
import Testing
@testable import Barry

struct SnapshotStalenessTests {
    @Test func staleAtTwoHoursNotBefore() throws {
        let combined = try Fixtures.combinedKLUK()
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = TendencySnapshot(from: combined, updatedAt: saved, atAirport: false)
        #expect(!snap.isStale(asOf: saved))
        #expect(!snap.isStale(asOf: saved.addingTimeInterval(2 * 3600 - 1)))
        #expect(snap.isStale(asOf: saved.addingTimeInterval(2 * 3600 + 1)))
        #expect(snap.station == "KLUK")
    }
}
