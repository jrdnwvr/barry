//  HeroView.swift
//  Barry — iOS
//
//  The glance. One block answers "what's the pressure doing here, right now, and is
//  weather coming?" — and makes the SOURCE of the number unmistakable:
//    • station + freshness (live dot when the sensor is trusted, else METAR age)
//    • the current pressure — the live calibrated sensor value (extra precision +
//      a LOCAL tag) when trusted, otherwise the coarser METAR value
//    • tap the value to compare phone vs station
//    • the live micro-trend (flagged when it's sharper than the station's 3h trend)
//    • calibration freshness + a manual Recalibrate control
//    • the plain-language verdict (honesty note only when confidence is low)

import SwiftUI

struct HeroView: View {
    let combined: CombinedResponse
    let unit: PressureUnit
    @ObservedObject var barometer: BarometerManager
    let now: Date
    var barometerEnabled: Bool
    /// An airport is selected or the user is within 3 NM: headline the
    /// field's altimeter setting instead of the sea-level pressure.
    var atAirport: Bool = false
    /// Saved-locations switcher (the station row becomes a menu when 2+ exist).
    var locations: [SavedLocation] = []
    var selectedLocationID: UUID? = nil
    var onSelectLocation: ((UUID) -> Void)? = nil

    @State private var showComparison = false
    @State private var showGuide = false

    private var tendency: TendencyOut? { combined.tendency }

    /// Time of the last station report — the local reading counts as "current" if it
    /// belongs to the same period (i.e. is at least as fresh as the last METAR).
    private var lastMetarTime: Date {
        combined.observedSeries.last?.t ?? combined.pressure.cachedAt
    }

    /// The local reading to show as "current": present, calibrated, and recent —
    /// from the same period as the last station report (or within the last hour),
    /// capped so a stale reading can't masquerade. Deliberately does NOT require the
    /// device to be stationary right now, so moving the phone doesn't hide it.
    private var localReading: (value: Double, at: Date)? {
        guard barometerEnabled, barometer.isCalibrated || barometer.isProvisional,
              let r = barometer.lastLocalReading else { return nil }
        let sameMetarPeriod = r.at >= lastMetarTime || now.timeIntervalSince(r.at) <= 3600
        let notAncient = now.timeIntervalSince(r.at) <= 2 * 3600
        guard sameMetarPeriod && notAncient else { return nil }
        return (combined.displayValue(fromLocalAltim: r.altim), r.at)
    }

    /// The reported altimeter setting wins at the airport; it is the number
    /// a pilot actually uses there, and it must not be blended with the
    /// phone's sea-level calibration.
    private var showsAltimeter: Bool { atAirport && combined.pressure.current.altim != nil }
    private var isLocal: Bool { localReading != nil && !showsAltimeter }
    private var displayValue: Double? {
        if showsAltimeter { return combined.pressure.current.altim }
        return localReading?.value ?? combined.currentPressure
    }

    /// The words under the number can roll up (a tap on the chevron or the
    /// bar); the choice sticks. Open by default.
    @AppStorage("heroWordsExpanded", store: AppConfig.sharedDefaults)
    private var wordsExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The instrument: station, number, tag, badge, in a soft card.
            VStack(alignment: .leading, spacing: 10) {
                statusRow
                numberBlock
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

            // The words hang off a bar in the tendency's color. The verdict
            // always shows; the supporting grey lines roll up behind the
            // chevron at the top of the bar.
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 4) {
                    Image(systemName: wordsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tendency?.cls.color(intensity: tendency?.intensity ?? 0) ?? .secondary)
                        .frame(width: 3)
                }
                .padding(.leading, 2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.25)) { wordsExpanded.toggle() } }
                .accessibilityLabel(wordsExpanded ? "Hide the reasoning" : "Show the reasoning")
                .accessibilityAddTraits(.isButton)
                wordsBlock
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $showGuide) { PressureGuideView() }
    }

    private var statusRow: some View {
        StatusRow(combined: combined, barometer: barometer, now: now,
                  barometerEnabled: barometerEnabled, localAt: localReading?.at,
                  locations: locations, selectedLocationID: selectedLocationID,
                  onSelectLocation: onSelectLocation)
    }

    private var numberBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let v = displayValue {
                            valueLabel(v)
                        }
                        Button { showGuide = true } label: {
                            Image(systemName: "info.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("What do pressure changes mean?")
                    }
                    if showsAltimeter {
                        altimeterRow
                            .padding(.top, -2)
                    }
                }
                Spacer(minLength: 8)
                if let t = tendency { TendencyBadge(tendency: t, unit: unit) }
            }
            if isLocal {
                provenanceRow
                if let trend = barometer.microTrend { microLead(trend) }
            }
        }
    }

    private var wordsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(combined.verdict)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { withAnimation(.snappy(duration: 0.25)) { wordsExpanded.toggle() } }
            if combined.lightningNearby == nil, let lt = combined.pressure.current.lightning {
                Label(lt.sentence, systemImage: lt.status == "distant" ? "bolt" : "bolt.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(lt.status == "thunderstorm" ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if wordsExpanded, let scale = rateContext {
                Text(scale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if wordsExpanded, let why = combined.reading?.explanation?.summary, !why.isEmpty {
                Text(why)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if wordsExpanded, let note = honestyNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Value (tap to compare)

    @ViewBuilder
    private func valueLabel(_ v: Double) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(valueString(v, live: isLocal))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit.label)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        if isLocal {
            Button { withAnimation(.snappy(duration: 0.2)) { showComparison.toggle() } } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    /// Live readings get extra precision (the sensor is far finer than a METAR);
    /// the precision itself signals the source at a glance.
    private func valueString(_ hPa: Double, live: Bool) -> String {
        let dp: Int
        switch unit {
        case .inHg: dp = live ? 3 : 2
        case .hPa:  dp = live ? 1 : 0
        }
        return String(format: "%.\(dp)f", unit.convert(hPa))
    }

    // MARK: - Altimeter tag

    /// "ALTIMETER · as reported at KLUK · sea level 30.24": says which number
    /// this is, and keeps the trend's own baseline one glance away.
    private var altimeterRow: some View {
        HStack(spacing: 8) {
            Text("ALTIMETER")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.blue.opacity(0.14), in: Capsule())
            Text(altimeterCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var altimeterCaption: String {
        var t = "as reported at \(combined.pressure.station)"
        if let slp = combined.currentPressure {
            t += " · sea level \(valueString(slp, live: false))"
        }
        return t
    }

    // MARK: - Provenance / comparison

    private var provenanceRow: some View {
        HStack(spacing: 8) {
            Text("LOCAL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.15), in: Capsule())

            if showComparison, let cmp = comparisonText {
                Text(cmp).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("tap to compare").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// "station 29.92 · phone −0.04" — how far the phone has moved off the station.
    private var comparisonText: String? {
        guard let local = localReading?.value, let station = combined.currentPressure else { return nil }
        let diff = unit.convertDelta(local - station)
        let dp = unit == .inHg ? 3 : 1
        let mag = String(format: "%.\(dp)f", abs(diff))
        let sign = diff > 0.0005 ? "+" : (diff < -0.0005 ? "−" : "±")
        return "station \(valueString(station, live: false)) · phone \(sign)\(mag)"
    }

    // MARK: - Micro-trend lead

    @ViewBuilder
    private func microLead(_ t: MicroTrend) -> some View {
        Label(microLabel(t), systemImage: "sensor.tag.radiowaves.forward")
            .font(.caption)
            .foregroundStyle(isSharperThanStation(t) ? Color.orange : Color.secondary)
    }

    private func microLabel(_ t: MicroTrend) -> String {
        let arrow = t.deltaHPa > 0.1 ? "↑" : (t.deltaHPa < -0.1 ? "↓" : "→")
        let mag = String(format: unit == .hPa ? "%.1f" : "%.2f", abs(unit.convertDelta(t.deltaHPa)))
        var s = "sensor \(arrow) \(mag) \(unit.label) in last \(t.windowMinutes) min"
        if isSharperThanStation(t) {
            s += t.deltaHPa < 0 ? ", falling faster than the station shows"
                                : ", rising faster than the station shows"
        }
        return s
    }

    /// The local trend (extrapolated to 3h) is meaningfully steeper than the METAR
    /// 3h tendency — i.e. the phone is catching a change before the next report.
    private func isSharperThanStation(_ t: MicroTrend) -> Bool {
        guard let metar3h = tendency?.delta3h else { return false }
        let hours = max(Double(t.windowMinutes) / 60.0, 1.0 / 12.0)
        let local3h = t.deltaHPa / hours * 3.0
        return abs(local3h) > abs(metar3h) + 0.7 && (local3h * metar3h >= 0 || abs(metar3h) < 0.3)
    }

    // MARK: - Honesty note

    /// "How fast is fast": the rate in the user's unit per hour, with a
    /// comparison to what fronts and storms typically do. Silent when the
    /// pressure is merely drifting.
    private var rateContext: String? {
        guard let r = combined.reading else { return nil }
        let mag = abs(r.rate3h)                       // hPa per 3 h
        guard mag >= 1.5 else { return nil }
        let perHour = unit.formatDelta(r.rate3h / 3).replacingOccurrences(of: "+", with: "")
        let scale = mag >= 3.0 ? "storm pace" : "front pace"
        return "\(perHour) per hour, \(scale)."
    }

    /// Surface non-obvious interpreter caveats (low confidence, sparse data).
    /// `forecast_derived` is already baked into the verdict sentence's hedged wording.
    /// One calm line whenever the reading deserves to be held loosely
    /// (disagreement with the forecast, thin or gappy reports, or low
    /// confidence). The reason itself isn't shown: the point is how to use
    /// the reading, not to alarm anyone about data plumbing.
    private var honestyNote: String? {
        guard let r = combined.reading else { return nil }
        let loosely = r.caveats.contains("model_disagrees")
            || r.caveats.contains("short_window")
            || r.caveats.contains("sparse")
            || r.confidence < 0.5
        return loosely ? "Low confidence." : nil
    }
}

// MARK: - Status row (station + freshness)

private struct StatusRow: View {
    let combined: CombinedResponse
    @ObservedObject var barometer: BarometerManager
    let now: Date
    var barometerEnabled: Bool
    /// When a recent local reading is being shown, its timestamp — surfaced as an age
    /// so the header reflects "we're showing local" rather than the raw motion state.
    var localAt: Date?
    var locations: [SavedLocation] = []
    var selectedLocationID: UUID? = nil
    var onSelectLocation: ((UUID) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let onSelectLocation, locations.count > 1 {
                Menu {
                    ForEach(locations) { loc in
                        Button {
                            onSelectLocation(loc.id)
                        } label: {
                            if loc.id == selectedLocationID {
                                Label(loc.title, systemImage: "checkmark")
                            } else {
                                Text(loc.title)
                            }
                        }
                    }
                } label: {
                    stationLabel(chevron: true)
                }
            } else {
                stationLabel(chevron: false)
            }
            Spacer(minLength: 8)
            freshness
        }
    }

    private func stationLabel(chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "airplane").font(.caption)
            Text(stationText)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)  // "Cincinnati/Lunken Fl…" -> fits
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var stationText: String {
        let code = combined.pressure.station
        if let name = combined.pressure.name, !name.isEmpty { return "\(code) · \(name)" }
        return code
    }

    @ViewBuilder
    private var freshness: some View {
        if let status = sensorStatus {
            HStack(spacing: 5) {
                if status.live {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
                Text(status.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.live ? Color.green : Color.secondary)
            }
        } else {
            // Two facts, stacked: how old the report is (the one that
            // matters in the air) and when Barry last checked for a new one.
            VStack(alignment: .trailing, spacing: 1) {
                Text(metarAge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("refreshed \(combined.pressure.cachedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
        }
    }

    /// Sensor status when the barometer feature is active + available; nil means
    /// fall back to METAR freshness.
    private var sensorStatus: (text: String, live: Bool)? {
        guard barometerEnabled else { return nil }
        // Showing a recent local reading → surface its trust tier + age, never the
        // raw motion classifier (which would say "Paused" while a perfectly good
        // carried-clean reading is on screen — a contradiction).
        if let localAt {
            let m = max(0, Int(now.timeIntervalSince(localAt) / 60))
            if m == 0 {
                return barometer.latestReadingIsCarried
                    ? ("Local · carried", true)
                    : ("Local · now", true)
            }
            return ("Local · \(m)m ago", false)
        }
        guard barometer.isAvailable else { return nil }
        switch barometer.motionState {
        case .stationary: return ("Calibrating…", false)
        case .settling:   return ("Settling…", false)
        case .moving:     return ("Paused", false)
        }
    }

    private var metarAge: String {
        let last = combined.observedSeries.last?.t ?? combined.pressure.cachedAt
        let mins = max(0, Int(now.timeIntervalSince(last) / 60))
        return mins < 60 ? "METAR \(mins)m ago" : "METAR \(mins / 60)h ago"
    }
}

// MARK: - Trend chip

struct TendencyBadge: View {
    let tendency: TendencyOut
    let unit: PressureUnit

    var body: some View {
        let color = tendency.cls.color(intensity: tendency.intensity)
        VStack(spacing: 2) {
            Image(systemName: tendency.cls.symbolName)
                .font(.title2.weight(.bold))
            Text(unit.formatDelta(tendency.delta3h))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text("3h")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}
