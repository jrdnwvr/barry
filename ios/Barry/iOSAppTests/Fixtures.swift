//  Fixtures.swift
//  BarryTests
//
//  The JSON the backend's tests use, read from this bundle. The tendency
//  cases are generated from the Python table; the combined payload is a
//  real /combined answer for KLUK captured on 2026-09-22 (TAF, runways,
//  sun times and all), so the timeline and card tests run on real shapes.

import Foundation
@testable import Barry

private final class BundleMarker {}

enum Fixtures {
    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name).\(ext) not in the test bundle"])
        }
        return try Data(contentsOf: url)
    }

    static func combinedKLUK() throws -> CombinedResponse {
        try BarryAPI.decoder.decode(CombinedResponse.self, from: data("combined_kluk"))
    }

    /// Ten minutes after the fixture's TAF hour began: 2026-09-22 00:10Z.
    static let fixtureNow = Date(timeIntervalSince1970: 1_790_035_800)
}
