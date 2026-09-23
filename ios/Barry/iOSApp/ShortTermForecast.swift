//  ShortTermForecast.swift
//  Barry — iOS
//
//  What the next hours do, worked out once for every forecast card style:
//  when rain arrives and eases, when the wind builds or swings, whether a
//  front comes through, the low or the high, clearing or clouding over.
//  Pure values over the model's hourly forecast, so the sentence and the
//  list of changes test without a view.

import Foundation

struct ShortTermForecast {
    struct Hour: Identifiable, Equatable {
        let t: Date
        let rain: Int
        let windKmh: Double?
        let gustKmh: Double?
        let dir: Double?
        let tempC: Double?
        let cloud: Double?
        let code: Int?
        var id: Date { t }
        var thunder: Bool { [95, 96, 99].contains(code ?? 0) }
        /// The strongest the wind gets this hour: the gust when there is one.
        var peakKmh: Double? { gustKmh.map { max($0, windKmh ?? 0) } ?? windKmh }
    }

    enum Kind: Int, Comparable {
        case rainStart, thunder, windUp, front, windShift, rainEnd, clearing, clouding, low, high
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Event: Identifiable, Equatable {
        let index: Int
        let t: Date
        let kind: Kind
        let text: String
        var id: String { "\(kind.rawValue)-\(index)" }
    }

    /// Where each change lands, as indices into `hours`.
    struct Found: Equatable {
        var rainStart: Int?
        var rainPeak: Int?
        var rainPeakEnd: Int?
        var rainEnd: Int?
        var thunder: Int?
        var windUp: Int?
        var shift: Int?
        var front = false
        var low: Int?
        var high: Int?
        var clearing: Int?
        var clouding: Int?
    }

    static let rainLikely = 30          // % from which rain is worth saying
    static let shiftDegrees = 60.0      // a wind shift, over two hours
    static let minShiftKmh = 9.0        // about 5 kt: lighter than this, direction is noise
    static let windRiseKmh = 15.0       // about 8 kt of build
    static let windNotableKmh = 28.0    // about 15 kt at the peak
    static let tempMoveC = 2.0
    static let frontDropC = 2.5

    let hours: [Hour]
    let found: Found

    init(forecast: [ForecastHour], now: Date, windowHours: Int = 12) {
        hours = forecast
            .filter { $0.t >= now.addingTimeInterval(-1800) }
            .prefix(windowHours + 1)
            .map { h in
                Hour(t: h.t, rain: h.precip_prob ?? 0, windKmh: h.windspeed, gustKmh: h.windgust,
                     dir: h.winddir, tempC: h.temperature, cloud: h.cloudcover, code: h.weather_code)
            }
        found = Self.find(hours)
    }

    var isEmpty: Bool { hours.count < 2 }

    // MARK: - Finding the changes

    static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    static func find(_ hours: [Hour]) -> Found {
        var f = Found()
        guard hours.count >= 2 else { return f }
        let r = hours.map(\.rain)
        let last = hours.count - 1

        // Rain: the first hour it becomes likely, the likeliest stretch, the easing.
        if let s = r.indices.first(where: { r[$0] >= rainLikely && ($0 == 0 || r[$0 - 1] < rainLikely) }) {
            f.rainStart = s
            if let p = r.indices.dropFirst(s).max(by: { r[$0] < r[$1] }) {
                var a = p, b = p
                while a > s, r[a - 1] >= r[p] - 10 { a -= 1 }
                while b < last, r[b + 1] >= r[p] - 10 { b += 1 }
                f.rainPeak = a
                f.rainPeakEnd = b
            }
            f.rainEnd = r.indices.first { $0 > s && r[$0] < rainLikely }
        }
        f.thunder = hours.indices.first { hours[$0].thunder }

        // Wind: a real build to a notable peak.
        let peaks = hours.map(\.peakKmh)
        if let start = peaks.compactMap({ $0 }).first,
           let top = peaks.indices.filter({ peaks[$0] != nil }).max(by: { peaks[$0]! < peaks[$1]! }),
           top > 0, let v = peaks[top], v - start >= windRiseKmh, v >= windNotableKmh {
            f.windUp = top
        }
        // A swing of 60° or more over two hours, with enough wind to mean it.
        if hours.count >= 3 {
            for i in 2...last {
                guard let a = hours[i - 2].dir, let b = hours[i].dir,
                      (hours[i - 2].windKmh ?? 0) >= minShiftKmh, (hours[i].windKmh ?? 0) >= minShiftKmh,
                      angle(a, b) >= shiftDegrees else { continue }
                f.shift = i
                // With a drop in temperature behind it, it is a front.
                if let before = hours[i - 1].tempC,
                   let after = hours[i...min(i + 3, last)].compactMap(\.tempC).min(),
                   before - after >= frontDropC {
                    f.front = true
                }
                break
            }
        }

        // Temperature: the low or the high, when the move is worth saying.
        let temps = hours.indices.compactMap { i in hours[i].tempC.map { (i, $0) } }
        if let t0 = temps.first?.1 {
            if let lo = temps.min(by: { $0.1 < $1.1 }), lo.0 > 0, t0 - lo.1 >= tempMoveC { f.low = lo.0 }
            if let hi = temps.max(by: { $0.1 < $1.1 }), hi.0 > 0, hi.1 - t0 >= tempMoveC { f.high = hi.0 }
        }

        // Sky: clearing after the thickest cover, or clouding over from a clear start.
        let clouds = hours.indices.compactMap { i in hours[i].cloud.map { (i, $0) } }
        if let top = clouds.max(by: { $0.1 < $1.1 }) {
            f.clearing = clouds.first { $0.0 > top.0 && $0.1 <= top.1 - 40 && $0.1 <= 50 }?.0
        }
        if f.rainStart == nil, let c0 = clouds.first?.1 {
            f.clouding = clouds.first { $0.1 >= c0 + 40 && $0.1 >= 70 }?.0
        }
        return f
    }

    // MARK: - Words

    static func clock(_ d: Date) -> String { d.formatted(.dateTime.hour()) }

    /// "midnight" and "noon" where a sentence reads better with them.
    static func spoken(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        if c.minute == 0, c.hour == 0 { return "midnight" }
        if c.minute == 0, c.hour == 12 { return "noon" }
        return clock(d)
    }

    static func cardinal(_ deg: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let d = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }

    static func sky(_ cloud: Double?) -> String? {
        guard let c = cloud else { return nil }
        switch c {
        case ..<20: return "clear"
        case ..<50: return "partly cloudy"
        case ..<85: return "mostly cloudy"
        default: return "overcast"
        }
    }

    /// "18 gusting 28 kts", or "18 kts" when the gust adds little.
    static func windText(_ h: Hour, _ unit: WindUnit) -> String {
        let w = h.windKmh ?? 0
        if let g = h.gustKmh, g >= w + 5.5 {
            return "\(unit.format(w)) gusting \(unit.format(g)) \(unit.label)"
        }
        return "\(unit.format(w)) \(unit.label)"
    }

    /// "16 G26", for tight spaces.
    static func windShort(_ h: Hour, _ unit: WindUnit) -> String {
        let w = h.windKmh ?? 0
        if let g = h.gustKmh, g >= w + 5.5 { return "\(unit.format(w)) G\(unit.format(g))" }
        return unit.format(w)
    }

    /// Two or three sentences naming every change, in order. A quiet stretch
    /// says so in one.
    func sentence(wind: WindUnit, temp: TemperatureUnit) -> String {
        guard !isEmpty else { return "" }
        let f = found
        var out: [String] = []
        if let s = f.rainStart {
            var p = s == 0 ? "Rain likely now" : "Rain moves in around \(Self.spoken(hours[s].t))"
            if let a = f.rainPeak, let b = f.rainPeakEnd, hours[a].rain >= 50, !(a == s && b == s) {
                p += a == b ? ", likeliest around \(Self.spoken(hours[a].t))"
                            : ", likeliest \(Self.clock(hours[a].t)) to \(Self.clock(hours[b].t))"
            }
            if let e = f.rainEnd { p += ", easing by \(Self.spoken(hours[e].t))" }
            out.append(p + ".")
        }
        if let th = f.thunder { out.append("Thunderstorms possible around \(Self.spoken(hours[th].t)).") }
        var shiftSaid = false
        if let w = f.windUp {
            var p = "Wind builds to \(Self.windText(hours[w], wind)) by \(Self.spoken(hours[w].t))"
            if let sh = f.shift, let d = hours[sh].dir, abs(sh - w) <= 2 {
                p += f.front ? " as a front comes through, swinging to the \(Self.cardinal(d))"
                             : " and swings to the \(Self.cardinal(d))"
                shiftSaid = true
            }
            out.append(p + ".")
        }
        if !shiftSaid, let sh = f.shift, let d = hours[sh].dir {
            out.append(f.front
                ? "A front comes through around \(Self.spoken(hours[sh].t)), the wind swinging to the \(Self.cardinal(d))."
                : "Wind swings to the \(Self.cardinal(d)) around \(Self.spoken(hours[sh].t)).")
        }
        var tail: [(Int, String)] = []
        if let i = f.clearing { tail.append((i, "clearing by \(Self.spoken(hours[i].t))")) }
        if let i = f.clouding { tail.append((i, "clouding over by \(Self.spoken(hours[i].t))")) }
        if let i = f.low, let t = hours[i].tempC { tail.append((i, "down to \(temp.format(t)) by \(Self.spoken(hours[i].t))")) }
        if let i = f.high, let t = hours[i].tempC { tail.append((i, "up to \(temp.format(t)) around \(Self.spoken(hours[i].t))")) }
        if !tail.isEmpty {
            let parts = tail.sorted { $0.0 < $1.0 }.map(\.1)
            let joined = parts.count <= 2 ? parts.joined(separator: " and ")
                                          : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            out.append(joined.prefix(1).uppercased() + joined.dropFirst() + ".")
        }
        if out.isEmpty {
            var p = "Steady through \(Self.clock(hours[hours.count - 1].t)): "
            p += (hours.map(\.rain).max() ?? 0) < 15 ? "dry" : "a slight chance of rain"
            if let t = hours[0].tempC { p += ", around \(temp.format(t))" }
            if hours[0].windKmh != nil { p += ", wind near \(Self.windText(hours[0], wind))" }
            out.append(p + ".")
        }
        return out.joined(separator: " ")
    }

    /// Each change as its own line, for the Changes card.
    func events(wind: WindUnit, temp: TemperatureUnit) -> [Event] {
        let f = found
        var out: [Event] = []
        func add(_ i: Int, _ k: Kind, _ text: String) { out.append(Event(index: i, t: hours[i].t, kind: k, text: text)) }
        if let s = f.rainStart, s > 0 {
            var p = "Rain moves in, \(hours[s].rain)%"
            if let a = f.rainPeak, hours[a].rain > hours[s].rain {
                p += ", rising to \(hours[a].rain)% by \(Self.clock(hours[a].t))"
            }
            add(s, .rainStart, p + ".")
        }
        if let e = f.rainEnd { add(e, .rainEnd, "Rain easing, \(hours[e].rain)%.") }
        if let th = f.thunder { add(th, .thunder, "Thunderstorms possible.") }
        let frontCarriesWind = f.front && f.windUp != nil && f.shift != nil && abs(f.windUp! - f.shift!) <= 1
        if let w = f.windUp, !frontCarriesWind { add(w, .windUp, "Wind builds to \(Self.windText(hours[w], wind)).") }
        if let sh = f.shift, let d = hours[sh].dir {
            if f.front {
                if frontCarriesWind, let w = f.windUp {
                    add(sh, .front, "Front passes. Wind swings to the \(Self.cardinal(d)), \(Self.windText(hours[w], wind)), and the temperature drops.")
                } else {
                    add(sh, .front, "Front passes. Wind swings to the \(Self.cardinal(d)) and the temperature drops.")
                }
            } else {
                add(sh, .windShift, "Wind swings to the \(Self.cardinal(d)), \(Self.windText(hours[sh], wind)).")
            }
        }
        if let i = f.clearing { add(i, .clearing, "Clearing.") }
        if let i = f.clouding { add(i, .clouding, "Clouding over.") }
        if let i = f.low, let t = hours[i].tempC { add(i, .low, "\(temp.format(t)), the low.") }
        if let i = f.high, let t = hours[i].tempC { add(i, .high, "\(temp.format(t)), the high.") }
        return out.sorted { ($0.index, $0.kind) < ($1.index, $1.kind) }
    }

    /// The first line of the Changes card: what it is doing now, preferring
    /// the station's own report over the model where there is one.
    func nowText(current: CurrentObs?, wind: WindUnit, temp: TemperatureUnit) -> String {
        guard let h = hours.first else { return "" }
        var parts: [String] = []
        if let t = current?.temp ?? h.tempC { parts.append(temp.format(t)) }
        let kmh = current?.windspeed ?? h.windKmh
        let dir = current?.winddir ?? h.dir
        if let kmh {
            if kmh < 4 { parts.append("calm") }
            else if let dir { parts.append("\(wind.format(kmh)) \(wind.label) from the \(Self.cardinal(dir))") }
            else { parts.append("\(wind.format(kmh)) \(wind.label)") }
        }
        parts.append(h.rain >= Self.rainLikely ? "rain \(h.rain)%" : "dry")
        let s = parts.joined(separator: ", ")
        return s.prefix(1).uppercased() + s.dropFirst() + "."
    }

    /// One hour in a line: "70% · 16 G26 kts · 56° · overcast".
    func readout(_ i: Int, wind: WindUnit, temp: TemperatureUnit) -> String {
        guard hours.indices.contains(i) else { return "" }
        let h = hours[i]
        var parts = ["\(h.rain)%"]
        if h.windKmh != nil { parts.append("\(Self.windShort(h, wind)) \(wind.label)") }
        if let t = h.tempC { parts.append(temp.format(t)) }
        if let s = Self.sky(h.cloud) { parts.append(s) }
        return parts.joined(separator: " · ")
    }
}
