//  ClockText.swift
//  Barry — Shared
//
//  Which clock the phone shows, for the few times written as words: an
//  hour in a sentence reads "4 PM" on a 12-hour clock and "16:00" on a
//  24-hour one, matching the times the system formats (".shortened").
//  The server is told the same thing (`clock=24`) for the verdict and the
//  reading, which it writes itself. Before 2026-09-26 those always read
//  "4 PM", beside cards that followed the phone's 24-hour setting.

import Foundation

enum ClockText {
    /// True when the phone shows a 24-hour clock, by the setting in
    /// Settings › General › Date & Time or the region's default.
    static func uses24Hour(locale: Locale = .current) -> Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return !pattern.contains("a")
    }

    /// The `clock` query value the server reads.
    static var queryValue: String { uses24Hour() ? "24" : "12" }

    /// An hour in a sentence: "4 PM", or "16:00" on a 24-hour clock.
    static func hour(_ d: Date, h24: Bool = uses24Hour(), locale: Locale = .current,
                     timeZone: TimeZone = .current) -> String {
        var style: Date.FormatStyle
        if h24 {
            // A 0-23 hour cycle on the locale itself: "16:00" in the US,
            // "16.00" where the region writes it so, never "04:00".
            var comps = Locale.Components(locale: locale)
            comps.hourCycle = .zeroToTwentyThree
            style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            style.locale = Locale(components: comps)
        } else {
            style = Date.FormatStyle.dateTime.hour()
            style.locale = locale
        }
        style.timeZone = timeZone
        return d.formatted(style)
    }

    /// An hour of the day (0 to 23), as `hour` would show it.
    static func hour(ofDay h: Int, h24: Bool = uses24Hour()) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return hour(d, h24: h24)
    }
}
