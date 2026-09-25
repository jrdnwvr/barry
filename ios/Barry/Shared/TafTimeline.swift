//  TafTimeline.swift
//  Barry — Shared
//
//  The TAF as a 24 hour timeline: category per hour from the base periods
//  (the TAF's own line, FM and BECMG groups), TEMPO and PROB windows kept
//  apart as chances over the base, night from the sun times, and the one
//  sentence that names every change in order. The app's TAF card and the
//  widget draw the same model. Where a field issues no TAF, the same strip
//  is drawn from MDL's LAMP guidance, hour by hour, and the sentence says
//  so ("LAMP: ...").

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

    enum Source { case taf, lamp }

    let source: Source
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
        let taf = combined.taf.flatMap { $0.periods.isEmpty ? nil : $0 }
        let lamp = combined.lamp.flatMap { $0.hours.isEmpty ? nil : $0 }
        guard taf != nil || lamp != nil else { return nil }
        self.now = now
        let cal = Calendar.current
        // The hour now is in, from its top. Setting the minute to zero
        // through the calendar moved forward to the next hour, so at ten
        // past the timeline began an hour ahead and the current hour was
        // missing; the fixture test caught it.
        let start = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let end = start.addingTimeInterval(24 * 3600)
        self.start = start
        self.end = end

        var hours: [Hour] = []
        if let taf {
            self.source = .taf
            self.issueTime = taf.issueTime
            let base = taf.periods.filter { $0.change == nil || $0.change == "FM" || $0.change == "BECMG" }
            let overlays = taf.periods.filter { $0.change == "TEMPO" || ($0.change ?? "").hasPrefix("PROB") }
            var t = start
            while t < end {
                let past = taf.validTo.map { t >= $0 } ?? false
                let b = past ? nil : base.last { $0.timeFrom <= t }?.fltCat
                let o = past ? nil : overlays.first { $0.timeFrom <= t && t < $0.timeTo }?.fltCat
                hours.append(Hour(t: t, base: b, tempo: o != b ? o : nil))
                t = t.addingTimeInterval(3600)
            }
            self.overlays = overlays.compactMap { p in
                guard let cat = p.fltCat, p.timeTo > start, p.timeFrom < end else { return nil }
                return Overlay(from: max(p.timeFrom, start), to: min(p.timeTo, end),
                               category: cat, isProb: (p.change ?? "").hasPrefix("PROB"))
            }
            self.tafEnds = taf.validTo.flatMap { $0 < end ? $0 : nil }
        } else {
            // LAMP is valid at the hour; each strip hour takes the nearest
            // LAMP hour within 45 minutes and is blank past the last one.
            let lamp = lamp!
            self.source = .lamp
            self.issueTime = lamp.runTime
            var t = start
            while t < end {
                let near = lamp.hours.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
                let b = near.flatMap { abs($0.t.timeIntervalSince(t)) <= 45 * 60 ? $0.fltCat : nil }
                hours.append(Hour(t: t, base: b, tempo: nil))
                t = t.addingTimeInterval(3600)
            }
            self.overlays = []
            let last = lamp.hours.last!.t.addingTimeInterval(1800)
            self.tafEnds = last < end ? last : nil
        }
        self.hours = hours

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
        guard let first = hours.first?.base else {
            return source == .taf ? "No category in the TAF." : "No category in LAMP."
        }
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
        let name = source == .taf ? "TAF" : "LAMP"
        if let obs = observedMismatch { return "Now \(obs). \(name): \(s)." }
        return source == .lamp ? "LAMP: \(s)." : s + "."
    }

    /// The short form for a lock screen line: "VFR until 2 AM, then MVFR".
    var shortSentence: String {
        guard let first = hours.first?.base else { return source == .taf ? "No TAF category" : "No LAMP category" }
        let lead = source == .lamp ? "LAMP " : ""
        let clock: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        if let change = hours.first(where: { $0.base != nil && $0.base != first }), let next = change.base {
            return "\(lead)\(first) until \(clock(change.t)), then \(next)"
        }
        return "\(lead)\(first) all day"
    }
}
