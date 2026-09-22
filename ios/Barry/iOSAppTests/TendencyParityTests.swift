//  TendencyParityTests.swift
//  BarryTests
//
//  Shared/Tendency.swift mirrors backend/app/tendency.py by hand. This test
//  reads the fixture the Python side generates from its table, so a
//  threshold changed on one side fails here until the other follows.

import Foundation
import Testing
@testable import Barry

struct TendencyParityTests {
    struct Case: Decodable {
        let delta3h: Double
        let cls: String
        let intensity: Double
        enum CodingKeys: String, CodingKey { case delta3h, cls = "class", intensity }
    }
    struct Doc: Decodable { let cases: [Case] }

    @Test func everyFixtureCaseClassifiesTheSameAsPython() throws {
        let doc = try JSONDecoder().decode(Doc.self, from: Fixtures.data("tendency_cases"))
        #expect(doc.cases.count >= 30)
        for c in doc.cases {
            #expect(TendencyClass.classify(delta3h: c.delta3h).rawValue == c.cls, "delta \(c.delta3h)")
            #expect(abs(TendencyIntensity.intensity(delta3h: c.delta3h) - c.intensity) < 5e-4, "delta \(c.delta3h)")
        }
        let classes = Set(doc.cases.map(\.cls))
        #expect(classes == Set(TendencyClass.allCases.map(\.rawValue)))
    }

    @Test func labelsAndSymbolsAreDistinctPerClass() {
        let labels = TendencyClass.allCases.map(\.label)
        let symbols = TendencyClass.allCases.map(\.symbolName)
        #expect(Set(labels).count == labels.count && labels.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == symbols.count)
        #expect(TendencyClass.fallingFast.isFalling && !TendencyClass.rising.isFalling && !TendencyClass.steady.isFalling)
    }
}
