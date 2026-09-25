//  AloftTests.swift
//  BarryTests
//
//  The column's math: the compressed altitude scale, the marks on a barb,
//  which levels fit, and the words.

import CoreGraphics
import Foundation
import Testing
@testable import Barry

struct AloftTests {
    @Test func theScaleGivesTheLowLevelsHalfTheHeight() {
        #expect(AloftScale.fraction(ft: 0, ceiling: 18000) == 1)
        #expect(abs(AloftScale.fraction(ft: 6000, ceiling: 18000) - 0.48) < 1e-9)
        #expect(abs(AloftScale.fraction(ft: 3000, ceiling: 18000) - 0.74) < 1e-9)
        #expect(abs(AloftScale.fraction(ft: 12000, ceiling: 18000) - 0.24) < 1e-9)
        #expect(AloftScale.fraction(ft: 18000, ceiling: 18000) == 0)
        #expect(AloftScale.fraction(ft: 25000, ceiling: 18000) == 0)
        // A 6,000 ft ceiling is plain linear.
        #expect(abs(AloftScale.fraction(ft: 3000, ceiling: 6000) - 0.5) < 1e-9)
        // The break stays at 6,000 whatever the ceiling.
        #expect(abs(AloftScale.fraction(ft: 6000, ceiling: 24000) - 0.48) < 1e-9)
    }

    @Test func barbMarksCountTheKnots() {
        #expect(WindBarb.marks(speedKt: 0).isEmpty)
        #expect(WindBarb.marks(speedKt: 2).isEmpty)
        #expect(WindBarb.marks(speedKt: 5) == [BarbMark(y: -10.5, kind: .half)])
        #expect(WindBarb.marks(speedKt: 12).map(\.kind) == [.full])
        #expect(WindBarb.marks(speedKt: 28).map(\.kind) == [.full, .full, .full])
        #expect(WindBarb.marks(speedKt: 28).map(\.y) == [-14, -10.5, -7])
        #expect(WindBarb.marks(speedKt: 35).map(\.kind) == [.full, .full, .full, .half])
        #expect(WindBarb.marks(speedKt: 48).map(\.kind) == [.pennant])         // rounds to 50
        #expect(WindBarb.marks(speedKt: 65).map(\.kind) == [.pennant, .full, .half])
    }

    @Test func rowsFitBetweenTheGroundAndTheCeilingWithoutOverlapping() {
        func lv(_ ft: Int) -> AloftLevel { AloftLevel(hPa: ft, ft: ft, tempC: 10) }
        let levels = [lv(300), lv(1000), lv(1200), lv(1400), lv(3000), lv(6000), lv(9900), lv(19000)]
        let shown = AloftRows.visible(levels, groundFt: 483, ceilingFt: 18000, plotHeight: 200)
        #expect(shown.map(\.ft) == [3000, 6000, 9900])           // 300 is under ground, 19,000 above the ceiling, the low three sit on the ground band
        let tall = AloftRows.visible(levels, groundFt: 483, ceilingFt: 18000, plotHeight: 2000)
        #expect(tall.map(\.ft) == [1000, 1200, 1400, 3000, 6000, 9900])
    }

    @Test func wordsUseTheRightSigns() {
        #expect(AloftFormat.degrees(-4.4) == "−4°" && AloftFormat.degrees(0.2) == "0°" && AloftFormat.degrees(15.6) == "16°")
        #expect(AloftFormat.direction(5) == "005°" && AloftFormat.direction(230) == "230°" && AloftFormat.direction(360) == "000°")
        #expect(AloftFormat.feet(12000) == "12,000")
    }
}

struct PressureLabelTests {
    @Test func isobarAndChangeLabelsFollowTheUnit() {
        #expect(PressureFieldRenderer.levelText(1012, .hPa) == "1012")
        #expect(PressureFieldRenderer.levelText(1012, .inHg) == "29.88")
        #expect(PressureFieldRenderer.levelText(1016, .inHg) == "30.00")
        #expect(PressureFieldRenderer.changeText(-2, .hPa) == "-2")
        #expect(PressureFieldRenderer.changeText(-2, .inHg) == "-0.06")
        #expect(PressureFieldRenderer.changeText(3, .inHg) == "0.09")
    }
}

/// Turbulence and icing now, from GTG and CIP, as runs the column draws.
struct AloftHazardTests {
    private let t = Date(timeIntervalSince1970: 1_790_300_000)

    @Test func turbulenceRunsFollowAWCsCategories() {
        let levels = [(1100, 0.05), (2100, 0.16), (3100, 0.25), (4100, 0.12), (8100, 0.4), (9100, 0.36)]
            .map { AloftTurbLevel(ft: $0.0, edr: $0.1) }
        let runs = AloftHazards.turbulence(AloftTurbulence(t: t, levels: levels), groundFt: 500, ceilingFt: 18000)
        #expect(runs.count == 2)
        #expect(runs[0] == HazardRun(baseFt: 1600, topFt: 3600, level: 2, words: "moderate turbulence"))
        #expect(runs[1].level == 3 && runs[1].words == "severe turbulence" && runs[1].baseFt == 7600)
        #expect(AloftHazards.turbulenceLevel(0.149) == 0 && AloftHazards.turbulenceLevel(0.15) == 1)
    }

    @Test func icingLeavesOutTraceAndNamesLargeDrops() {
        let levels = [
            AloftIceLevel(ft: 5000, prob: 0.1, severity: 1),
            AloftIceLevel(ft: 5500, prob: 0.3, severity: 2),
            AloftIceLevel(ft: 6000, prob: 0.5, severity: 3, sld: 0.6),
            AloftIceLevel(ft: 6500, prob: 0.2, severity: 1),
        ]
        let runs = AloftHazards.icing(AloftIcing(t: t, levels: levels), groundFt: 0, ceilingFt: 12000)
        #expect(runs == [HazardRun(baseFt: 5250, topFt: 6250, level: 2, words: "moderate icing, large drops")])
    }

    @Test func runsAreClippedToTheColumn() {
        let levels = [AloftTurbLevel(ft: 11100, edr: 0.2), AloftTurbLevel(ft: 12100, edr: 0.2), AloftTurbLevel(ft: 13100, edr: 0.2)]
        let runs = AloftHazards.turbulence(AloftTurbulence(t: t, levels: levels), groundFt: 0, ceilingFt: 12000)
        #expect(runs.count == 1 && runs[0].topFt == 12000 && runs[0].baseFt == 10600)
        #expect(AloftHazards.turbulence(nil, groundFt: 0, ceilingFt: 12000).isEmpty)
    }
}
