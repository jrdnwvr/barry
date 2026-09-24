//  Fixtures.swift
//  BarryTests
//
//  The JSON the backend's tests use, read from this bundle. The tendency
//  cases are generated from the Python table; the combined payload is a
//  real /combined answer for KLUK captured on 2026-09-22 (TAF, runways,
//  sun times and all), so the timeline and card tests run on real shapes.

import Foundation
import Testing
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

    /// The front night the forecast card designs were drawn on: rain in
    /// from the fourth hour, likeliest in the sixth and seventh, the wind
    /// building to 18 gusting 28 kt and swinging northwest in the seventh
    /// as the temperature falls, clearing and the low near dawn, then a
    /// fair day. Hour 0 is 00:00Z, the fixture's now rounded down.
    static let frontHours: [(tempC: Double, kt: Double, gustKt: Double, dir: Double, rain: Int, cloud: Double)] = [
        (17, 7, 11, 215, 3, 40), (16.5, 8, 12, 215, 5, 55), (16, 9, 14, 220, 10, 70), (15.5, 11, 17, 220, 20, 85),
        (15, 13, 21, 225, 35, 95), (14.5, 15, 24, 225, 55, 100), (13.5, 16, 26, 230, 70, 100), (11.5, 18, 28, 300, 60, 100),
        (10, 16, 25, 305, 35, 90), (9, 13, 20, 310, 20, 70), (8, 11, 17, 315, 10, 50), (7.5, 9, 14, 315, 5, 35),
        (8, 8, 12, 315, 3, 25), (9.5, 8, 12, 320, 2, 20), (11, 9, 13, 320, 1, 15), (12.5, 9, 14, 320, 1, 10),
        (14, 10, 15, 315, 0, 10), (15, 10, 16, 310, 0, 10), (16, 10, 16, 305, 0, 15), (16.5, 9, 15, 300, 0, 20),
        (16.5, 8, 13, 295, 0, 20), (16, 7, 11, 290, 0, 15), (15, 6, 10, 285, 0, 10), (14, 5, 8, 280, 0, 10), (13, 4, 7, 275, 0, 10),
    ]

    static func frontForecast(start: Date = Date(timeIntervalSince1970: 1_790_035_200)) -> [ForecastHour] {
        frontHours.enumerated().map { i, h in
            let code = h.rain >= 55 ? 63 : (h.rain >= 30 ? 61 : (h.cloud >= 90 ? 3 : (h.cloud >= 50 ? 2 : (h.cloud >= 15 ? 1 : 0))))
            return ForecastHour(t: start.addingTimeInterval(Double(i) * 3600), pressure_msl: 1012,
                                windspeed: h.kt * 1.852, winddir: h.dir, windgust: h.gustKt * 1.852,
                                precip_prob: h.rain, temperature: h.tempC, dewpoint: h.tempC - 2,
                                cloudcover: h.cloud, weather_code: code)
        }
    }

    /// The KLUK payload with the front night as its forecast; `dry` takes
    /// every drop of rain out of it.
    static func combinedFrontNight(dry: Bool = false) throws -> CombinedResponse {
        var obj = try #require(try JSONSerialization.jsonObject(with: data("combined_kluk")) as? [String: Any])
        var forecast = try #require(obj["forecast"] as? [String: Any])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var hours = frontForecast()
        if dry {
            hours = hours.map { h in
                ForecastHour(t: h.t, pressure_msl: h.pressure_msl, windspeed: h.windspeed, winddir: h.winddir,
                             windgust: h.windgust, precip_prob: 0, temperature: h.temperature, dewpoint: h.dewpoint,
                             cloudcover: h.cloudcover, weather_code: 3)
            }
        }
        forecast["hourly"] = try JSONSerialization.jsonObject(with: enc.encode(hours))
        obj["forecast"] = forecast
        return try BarryAPI.decoder.decode(CombinedResponse.self, from: JSONSerialization.data(withJSONObject: obj))
    }
}
