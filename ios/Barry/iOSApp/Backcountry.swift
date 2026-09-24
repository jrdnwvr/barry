//  Backcountry.swift
//  Barry — iOS
//
//  Off-field, in addition to the station's report and never in place of it.
//  Two rules keep it out of the way:
//    1. Situation: the Strip card exists only when the user is not at an
//       airport (no airport selected, not within 3 NM of the station).
//    2. The Backcountry toggle: facts (the nearest station, its distance,
//       elevation difference and age) show for anyone off-field; estimates
//       (an altimeter setting, the panel check, strip density altitude and
//       wind from the model) join only when the toggle is on, and every one
//       of them is marked "est."

import CoreLocation
import SwiftUI

enum Backcountry {
    static let enabledKey = "backcountryEnabled"
    static let acknowledgedKey = "backcountryAcknowledged"
    static let rangeKey = "backcountryRangeNM"

    static let disclaimer = "Estimates come from the nearest station, the forecast model, and this device's sensor. They are not a reported altimeter setting and do not satisfy 14 CFR 91.121. Use a reported setting from a station within 100 NM when one exists; otherwise set field elevation before takeoff. Never for an instrument approach."
}

// MARK: - The numbers

/// Everything the Strip card can say, computed once from the payload, the
/// user's position, and the phone sensor.
struct StripEstimate {
    struct Source { let name: String; let altimHPa: Double }

    var sources: [Source] = []
    /// Altimeter setting estimate in hPa; the sensor wins, then the station.
    var altimHPa: Double?
    /// Half the spread of the sources, floored at 0.3 hPa (a hundredth of an inch).
    var plusMinusHPa: Double?
    var rough = false
    var densityAltitudeFt: Int?
    var windKt: Int?
    var windDirDeg: Int?
    var temperatureC: Double?

    /// Nearest station facts.
    var stationDistanceNM: Double?
    var stationCardinal: String?
    var stationElevDiffFt: Int?
    var reportAge: TimeInterval?

    static func make(combined: CombinedResponse, now: Date,
                     here: CLLocationCoordinate2D?, hereAltitudeM: Double?,
                     sensorAltimHPa: Double?, sensorAt: Date?) -> StripEstimate {
        var e = StripEstimate()
        let cur = combined.pressure.current

        // Station facts.
        if let here, let slat = combined.pressure.lat, let slon = combined.pressure.lon {
            let km = haversineKm(here.latitude, here.longitude, slat, slon)
            e.stationDistanceNM = km / 1.852
            e.stationCardinal = cardinalWord(bearingDeg(here.latitude, here.longitude, slat, slon))
        }
        if let hereAltitudeM, let selev = combined.pressure.elevM {
            e.stationElevDiffFt = Int(((selev - hereAltitudeM) * 3.28084).rounded())
        }
        if let last = combined.observedSeries.last?.t {
            e.reportAge = now.timeIntervalSince(last)
        }

        // Sources for the setting, altimeter kind.
        if let a = sensorAltimHPa, let at = sensorAt, now.timeIntervalSince(at) < 2 * 3600 {
            e.sources.append(Source(name: "sensor", altimHPa: a))
        }
        if let a = cur.altim {
            e.sources.append(Source(name: combined.pressure.station, altimHPa: a))
        }
        let hour = (combined.forecast?.hourly ?? []).min { abs($0.t.timeIntervalSince(now)) < abs($1.t.timeIntervalSince(now)) }
        if let h = hour, abs(h.t.timeIntervalSince(now)) < 2 * 3600 {
            if let pm = h.pressure_msl, let slp = cur.slp, let alt = cur.altim {
                e.sources.append(Source(name: "model", altimHPa: pm + (alt - slp)))
            }
            e.temperatureC = h.temperature
            if let ws = h.windspeed { e.windKt = Int((ws * 0.539957).rounded()) }
            if let wd = h.winddir { e.windDirDeg = Int(wd.rounded()) }
        }
        if let first = e.sources.first {
            e.altimHPa = first.altimHPa
            let vs = e.sources.map(\.altimHPa)
            let spread = (vs.max() ?? 0) - (vs.min() ?? 0)
            e.plusMinusHPa = max(spread / 2, 0.3)
            e.rough = spread > 1.7 || (e.stationDistanceNM ?? 0) > 50
        }

        // Density altitude at the spot: FAA rule of thumb on pressure altitude.
        if let a = e.altimHPa, let hm = hereAltitudeM, let t = e.temperatureC {
            let elevFt = hm * 3.28084
            let pa = elevFt + 145366.45 * (1 - pow(a / 1013.25, 0.190284))
            let isa = 15.0 - 1.98 * pa / 1000.0
            let da = pa + 118.8 * (t - isa)
            e.densityAltitudeFt = Int((da / 50).rounded() * 50)
        }
        return e
    }

    /// With this setting dialed, the panel altimeter should read the elevation here.
    func panelShouldReadFt(hereAltitudeM: Double?) -> Int? {
        guard altimHPa != nil, let hm = hereAltitudeM else { return nil }
        return Int(((hm * 3.28084) / 10).rounded() * 10)
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = pow(sin((p2 - p1) / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 2 * r * asin(sqrt(a))
    }

    static func bearingDeg(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let x = sin(dl) * cos(p2)
        let y = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(x, y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func cardinalWord(_ deg: Double) -> String {
        let words = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return words[Int(((deg + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
    }
}

// MARK: - The card

struct StripCard: View {
    let combined: CombinedResponse
    let now: Date
    let unit: PressureUnit
    /// The user's position: the device when the selection is My location,
    /// the saved place otherwise.
    let here: CLLocationCoordinate2D?
    /// True when `here` is where the device physically is (GPS altitude is
    /// meaningful, the sensor applies).
    let physical: Bool
    @ObservedObject var barometer: BarometerManager
    let sensorEnabled: Bool

    @AppStorage(Backcountry.enabledKey, store: AppConfig.sharedDefaults)
    private var enabled: Bool = false
    @State private var altitude: (meters: Double, accuracy: Double)?
    @State private var showInfo = false

    private var estimate: StripEstimate {
        let sensor = (enabled && sensorEnabled && barometer.isCalibrated)
            ? barometer.lastLocalReading : nil
        return StripEstimate.make(combined: combined, now: now, here: here,
                                  hereAltitudeM: physical ? altitude?.meters : nil,
                                  sensorAltimHPa: sensor?.altim, sensorAt: sensor?.at)
    }

    var body: some View {
        let e = estimate
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "mountain.2")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("Here")
                    .font(.subheadline.weight(.medium))
                if enabled {
                    Text("est.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Spacer()
                if enabled {
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if enabled {
                if let a = e.altimHPa {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Altimeter \(unit.format(a)) est.")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                        Spacer()
                        if let pm = e.plusMinusHPa {
                            Text((e.rough ? "rough · " : "") + "±\(plusMinus(pm))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Text(e.sources.map { "\($0.name) \(unit.format($0.altimHPa))" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if let ft = e.panelShouldReadFt(hereAltitudeM: physical ? altitude?.meters : nil) {
                        Text("Set \(unit.format(a)), panel should read about \(ft.formatted()) ft")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if e.densityAltitudeFt != nil || e.windKt != nil {
                    HStack(spacing: 6) {
                        if let da = e.densityAltitudeFt {
                            Text("Density altitude \(da.formatted()) ft")
                        }
                        if e.densityAltitudeFt != nil, e.windKt != nil { Text("·") }
                        if let kt = e.windKt, let d = e.windDirDeg {
                            Text("Wind \(String(format: "%03d", d)) at \(kt) model")
                        }
                    }
                    .font(.caption).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                }
            }

            Text(stationLine(e))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .task(id: physical) {
            guard physical else { altitude = nil; return }
            altitude = await barometer.currentAltitude()
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(e.sources, id: \.name) { s in
                            HStack {
                                Text(s.name).font(.subheadline)
                                Spacer()
                                Text("\(unit.format(s.altimHPa)) \(unit.label)").font(.subheadline).monospacedDigit()
                            }
                        }
                        Text(Backcountry.disclaimer)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .navigationTitle("Estimated, advisory only")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }

    private func plusMinus(_ hPa: Double) -> String {
        let v = unit.convertDelta(hPa)
        return String(format: unit == .hPa ? "%.1f" : "%.2f", v)
    }

    /// "KI67 12 NM north, 350 ft lower, 20 min ago"
    private func stationLine(_ e: StripEstimate) -> String {
        var parts: [String] = [combined.pressure.station]
        if let d = e.stationDistanceNM, let c = e.stationCardinal {
            parts[0] += " \(Int(d.rounded())) NM \(c)"
        }
        if let diff = e.stationElevDiffFt, abs(diff) >= 100 {
            parts.append("\(abs(diff).formatted()) ft \(diff > 0 ? "higher" : "lower")")
        }
        if let age = e.reportAge {
            let m = max(0, Int(age / 60))
            parts.append(m < 60 ? "\(m) min ago" : "\(m / 60) h \(m % 60) min ago")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The one-time acknowledgement

struct BackcountryAckSheet: View {
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(Backcountry.disclaimer)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    onAccept()
                    dismiss()
                } label: {
                    Text("I understand").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Backcountry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
