//  TafTimelineTests.swift
//  BarryTests
//
//  The 24 hour timeline built from a real KLUK TAF: base periods, a PROB
//  window as a chance over the base, sun marks, and the sentence.

import Foundation
import Testing
@testable import Barry

struct TafTimelineTests {
    @Test func hoursFollowTheBasePeriodsAndTheProbWindowIsAnOverlay() throws {
        let combined = try Fixtures.combinedKLUK()
        let tl = try #require(TafTimeline(combined: combined, now: Fixtures.fixtureNow))
        #expect(tl.hours.count == 24)
        let bases = tl.hours.map { $0.base ?? "-" }
        #expect(bases[0..<6].allSatisfy { $0 == "MVFR" })
        #expect(bases[6..<16].allSatisfy { $0 == "IFR" })
        #expect(bases[16..<24].allSatisfy { $0 == "MVFR" })
        #expect(tl.runs.count == 3)
        #expect(tl.overlays.count == 1 && tl.overlays[0].isProb && tl.overlays[0].category == "IFR")
        #expect(tl.hours[0].tempo == "IFR" && tl.hours[6].tempo == nil)
        #expect(tl.observedMismatch == nil)                 // METAR says MVFR, so does hour one
        #expect(tl.sunMarks.count == 2 && tl.sunMarks[0].1 == false && tl.sunMarks[1].1 == true)
        #expect(tl.tafEnds == nil)                          // the TAF runs past the window
    }

    @Test func theSentenceNamesEveryChangeInOrder() throws {
        let combined = try Fixtures.combinedKLUK()
        let tl = try #require(TafTimeline(combined: combined, now: Fixtures.fixtureNow))
        let s = tl.sentence
        #expect(s.hasPrefix("MVFR until "))
        #expect(s.contains(", then IFR"))
        #expect(s.contains("MVFR again by"))
        #expect(s.contains("Chance of IFR"))
        #expect(s.hasSuffix("."))
        #expect(tl.shortSentence.hasPrefix("MVFR until ") && tl.shortSentence.hasSuffix("then IFR"))
    }

    @Test func noTafMeansNoTimeline() throws {
        var combined = try Fixtures.combinedKLUK()
        combined.taf = nil
        #expect(TafTimeline(combined: combined, now: Fixtures.fixtureNow) == nil)
    }
}
