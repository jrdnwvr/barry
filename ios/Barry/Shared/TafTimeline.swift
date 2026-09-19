//  TafTimeline.swift
//  Barry — Shared
//
//  The TAF as a 24 hour timeline: category per hour from the base periods
//  (the TAF's own line, FM and BECMG groups), TEMPO and PROB windows kept
//  apart as chances over the base, night from the sun times, and the one
//  sentence that names every change in order. The app's TAF card and the
//  widget draw the same model.

import Foundation

struct TafTimeline {
    struct Hour: Identifiable {
        let t: Date
        let base: String?
        let tempo: String?
        var id: Date { t }
    }

    struct Overlay: Identifiable {
        let from: Date
        let to: Date
        let category: String
        let isProb: Bool
        var id: Date { from }
    }

    let start: Date
    let end: Date
    let now: Date
    let hours: [Hour]
    let overlays: [Overlay]
    /// (time, isSunset), inside the window.
    let sunMarks: [(Date, Bool)]
    let nights: [(Date, Date)]
    /// The TAF's valid-to time when it falls inside the window.
    let tafEnds: Date?
    let issueTime: Date?
    /// The METAR's category when it disagrees with the TAF's for this hour.
    let observedMismatch: String?

    var isEmpty: Bool { hours.isEmpty }

    init?(combined: CombinedResponse, now: Date) {
        guard let taf = combined.taf, !taf.periods.isEmpty else { return nil }
        self.now = now
        let cal = Calendar.current
        let start = cal.date(bySetting: .minute, value: 0, of: now).map { cal.date(bySetting: .second, value: 0, of: $0) ?? $0 } ?? now
        let end = start.addingTimeInterval(24 * 3600)
        self.start = start
        self.end = end
        self.issueTime = taf.issueTime

        let base = taf.periods.filter { $0.change == nil || $0.change == "FM" || $0.change == "BECMG" }
        let overlays = taf.periods.filter { $0.change == "TEMPO" || ($0.change ?? "").hasPrefix("PROB") }
        var hours: [Hour] = []
        var t = start
        while t < end {
            let past = taf.validTo.map { t >= $0 } ?? false
            let b = past ? nil : base.last { $0.timeFrom <= t }?.fltCat
            let o = past ? nil : overlays.first { $0.timeFrom <= t && t < $0.timeTo }?.fltCat
            hours.append(Hour(t: t, base: b, tempo: o != b ? o : nil))
            t = t.addingTimeInterval(3600)
        }
        self.hours = hours

        self.overlays = overlays.compactMap { p in
            guard let cat = p.fltCat, p.timeTo > start, p.timeFrom < end else { return nil }
            return Overlay(from: max(p.timeFrom, start), to: min(p.timeTo, end),
                           category: cat, isProb: (p.change ?? "").hasPrefix("PROB"))
        }

        let sun = combined.forecast?.sun
        let sets = (sun?.sunset ?? []).sorted()
        let rises = (sun?.sunrise ?? []).sorted()
        self.sunMarks = (sets.filter { $0 >= start && $0 <= end }.map { ($0, true) }
                         + rises.filter { $0 >= start && $0 <= end }.map { ($0, false) })
            .sorted { $0.0 < $1.0 }
        var nights: [(Date, Date)] = []
        if let lastSet = sets.last(where: { $0 <= start }),
           let nextRise = rises.first(where: { $0 > lastSet }), nextRise > start {
            nights.append((start, min(nextRise, end)))
        }
        for s in sets where s >= start && s < end {
            let r = rises.first { $0 > s } ?? end
            nights.append((s, min(r, end)))
        }
        self.nights = nights
        self.tafEnds = taf.validTo.flatMap { $0 < end ? $0 : nil }

        if let obs = combined.pressure.current.fltCat, let first = hours.first?.base, obs != first {
            self.observedMismatch = obs
        } else {
            self.observedMismatch = nil
        }
    }

    /// Consecutive hours of one category as (category, from, to).
    var runs: [(String?, Date, Date)] {
        var out: [(String?, Date, Date)] = []
        for h in hours {
            if let last = out.last, last.0 == h.base {
                out[out.count - 1].2 = h.t.addingTimeInterval(3600)
            } else {
                out.append((h.base, h.t, h.t.addingTimeInterval(3600)))
            }
        }
        return out
    }

    /// "VFR until 2 AM, then MVFR, LIFR by 4 AM, VFR again by 9 AM."
    /// Every change in the window, in order, so the worst hour is never
    /// hidden behind the first change. A bust leads: "Now MVFR. TAF: ...".
    var sentence: String {
        guard let first = hours.first?.base else { return "No category in the TAF." }
        let clock: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        var changes: [(String, Date)] = [(first, hours[0].t)]
        for h in hours { if let b = h.base, b != changes.last!.0 { changes.append((b, h.t)) } }
        var s: String
        if changes.count == 1 {
            s = end.timeIntervalSince(start) >= 20 * 3600 ? "\(first) all day" : "\(first) through \(clock(end))"
        } else {
            let (second, at) = changes[1]
            let improving = FlightCategory.rank(second) > FlightCategory.rank(first)
            s = improving ? "\(first), \(second == "VFR" ? "lifting to VFR" : "improving to \(second)") around \(clock(at))"
                          : "\(first) until \(clock(at)), then \(second)"
            for (cat, at) in changes.dropFirst(2).prefix(3) {
                s += cat == first ? ", \(cat) again by \(clock(at))" : ", \(cat) by \(clock(at))"
            }
        }
        if let tempo = hours.first(where: { $0.tempo != nil }), let cat = tempo.tempo {
            let last = hours.last { $0.tempo == cat }?.t ?? tempo.t
            s += ". Chance of \(cat) \(clock(tempo.t)) to \(clock(last.addingTimeInterval(3600)))"
        }
        if let obs = observedMismatch { return "Now \(obs). TAF: \(s)." }
        return s + "."
    }

    /// The short form for a lock screen line: "VFR until 2 AM, then MVFR".
    var shortSentence: String {
        guard let first = hours.first?.base else { return "No TAF category" }
        let clock: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        if let change = hours.first(where: { $0.base != nil && $0.base != first }), let next = change.base {
            return "\(first) until \(clock(change.t)), then \(next)"
        }
        return "\(first) all day"
    }

    var hatchCaption: String? {
        guard !overlays.isEmpty else { return nil }
        return overlays.contains { $0.isProb } ? "Hatched: TEMPO or PROB, a chance over the base forecast."
                                               : "Hatched: TEMPO, a chance over the base forecast."
    }
}
