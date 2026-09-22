//  RunwayMathTests.swift
//  BarryTests
//
//  The wind projected onto runway ends, and the words it becomes.

import Foundation
import Testing
@testable import Barry

struct RunwayMathTests {
    let rwy = Runway(le: "03", he: "21", leHeading: 30, heHeading: 210, lengthFt: 6000)

    @Test func componentsAndOrderFavourTheHeadwindEnd() {
        let out = RunwayWinds.compute(runways: [rwy], windDirDeg: 240, windKt: 12, gustKt: 18)
        #expect(out.map(\.ident) == ["21", "03"])
        let best = out[0]
        #expect(abs(best.headwind - 12 * cos(30 * Double.pi / 180)) < 0.01)
        #expect(abs(best.crosswind - 6) < 0.01 && best.crosswind > 0)          // from the right
        #expect(abs((best.gustCrosswind ?? 0) - 9) < 0.01)
        #expect(!best.isTailwind && out[1].isTailwind)
        #expect(abs(out[1].headwind + best.headwind) < 0.01)
    }

    @Test func calmOrUnknownWindGivesNothing() {
        #expect(RunwayWinds.compute(runways: [rwy], windDirDeg: nil, windKt: 12, gustKt: nil).isEmpty)
        #expect(RunwayWinds.compute(runways: [rwy], windDirDeg: 240, windKt: 0.4, gustKt: nil).isEmpty)
        #expect(RunwayWinds.compute(runways: [], windDirDeg: 240, windKt: 12, gustKt: nil).isEmpty)
    }

    @Test func sentencesSayTheRightSideAndOnlyMentionGustsThatMatter() {
        let out = RunwayWinds.compute(runways: [rwy], windDirDeg: 240, windKt: 12, gustKt: 18)
        #expect(RunwayWinds.sentence(out[0]) == "6 kt crosswind from the right, 10 kt headwind. Gusts push the crosswind to 9 kt.")
        #expect(RunwayWinds.compact(out[0]) == "Rwy 21 · 6 kt from the right")
        let straight = RunwayWinds.compute(runways: [rwy], windDirDeg: 210, windKt: 10, gustKt: 12)[0]
        #expect(RunwayWinds.sentence(straight) == "10 kt headwind.")
        #expect(RunwayWinds.compact(straight) == "Rwy 21 · straight down")
        let left = RunwayWinds.compute(runways: [rwy], windDirDeg: 180, windKt: 10, gustKt: nil)[0]
        #expect(RunwayWinds.sentence(left).contains("from the left"))
    }

    @Test func parallelsCollapseToTheNumber() {
        #expect(Runway.base("18L") == "18" && Runway.base("36C") == "36" && Runway.base("07") == "07" && Runway.base("L") == "L")
    }

    @Test func modeDecidesWhenRunwaysApply() {
        #expect(RunwayWindsMode.always.usesRunways(atAirport: false))
        #expect(RunwayWindsMode.auto.usesRunways(atAirport: true) && !RunwayWindsMode.auto.usesRunways(atAirport: false))
        #expect(!RunwayWindsMode.compass.usesRunways(atAirport: true))
    }
}
