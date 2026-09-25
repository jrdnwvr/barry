//  RainLine.swift
//  Barry — iOS
//
//  The words for the Conditions card's rain row: a title from when the
//  rain arrives or clears, and the server's detail with its clearing time
//  filled in. Pure, so the wording is tested.

import Foundation

enum RainLine {
    static func title(_ r: RainOut, now: Date) -> String {
        if r.status == "now" {
            if let end = r.endsAt { return "Rain until about \(time(end))" }
            return "Raining now"
        }
        guard let start = r.startsAt else { return "Rain on the way" }
        if start.timeIntervalSince(now) < 150 { return "Rain any minute" }
        return "Rain from about \(time(start))"
    }

    static func detail(_ r: RainOut) -> String {
        r.detail.replacingOccurrences(of: "{end}", with: r.endsAt.map(time) ?? "later")
    }

    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }
}
