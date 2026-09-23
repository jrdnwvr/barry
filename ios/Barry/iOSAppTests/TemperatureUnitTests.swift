//  TemperatureUnitTests.swift
//  BarryTests

import Foundation
import Testing
@testable import Barry

struct TemperatureUnitTests {
    @Test func conversionsAndWords() {
        #expect(TemperatureUnit.celsius.format(16.4) == "16°" && TemperatureUnit.celsius.format(-3.6) == "−4°")
        #expect(TemperatureUnit.fahrenheit.format(0) == "32°" && TemperatureUnit.fahrenheit.format(100) == "212°")
        #expect(TemperatureUnit.fahrenheit.format(-40) == "−40°")
        #expect(TemperatureUnit.fahrenheit.formatWithUnit(20) == "68°F" && TemperatureUnit.celsius.formatWithUnit(20) == "20°C")
        #expect(TemperatureUnit.fahrenheit.formatDelta(5) == "9°" && TemperatureUnit.celsius.formatDelta(5) == "5°")
        #expect(TemperatureUnit.fahrenheit.freezing == 32 && TemperatureUnit.celsius.freezing == 0)
        #expect(TemperatureUnit.allCases.map(\.label) == ["°C", "°F"])
    }
}
