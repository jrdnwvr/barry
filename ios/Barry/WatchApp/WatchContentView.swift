//  WatchContentView.swift
//  Barry — watchOS
//
//  Condensed quick-look (brief §3, Phase 4): trend glyph, current value, 3h delta,
//  the last six hours as a small chart, and the one-line verdict. Fetches via
//  the same backend; the shared snapshot doubles as an offline fallback.
//
//  The headline is the same number the complication shows: the field's
//  altimeter setting when the phone has an airport chosen or the wearer is
//  within 3 NM of the station, the sea-level pressure otherwise. The store
//  makes that call once (`atAirport`) and writes it into the snapshot.

import SwiftUI
import Charts

struct WatchContentView: View {
    @EnvironmentObject var store: PressureStore
    @EnvironmentObject var barometer: WatchBarometer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("watchBarometerEnabled", store: AppConfig.sharedDefaults)
    private var barometerEnabled: Bool = false
    @AppStorage("backcountryEnabled", store: AppConfig.sharedDefaults)
    private var backcountryEnabled: Bool = false
    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    @State private var lastLocalSnapshotAt: Date = .distantPast

    /// Data older than this is refreshed when the app comes to the front, so
    /// the page never trails the complication (which refreshes every ~20 min).
    private static let refreshAfter: TimeInterval = 3 * 60

    var body: some View {
        NavigationStack {
            ScrollView {
                switch store.state {
                case .idle, .loading:
                    fallbackOrSpinner
                case .failed:
                    fallbackOrError
                case .loaded(let combined):
                    loaded(combined)
                }
            }
            .navigationTitle(store.station)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task {
                // The phone's station and airport choice, now and whenever
                // it changes while the app is open.
                PhoneSync.shared.onUpdate = { station, selected, physical in
                    store.station = station
                    store.airportSelected = selected
                    store.selectionPhysical = physical
                    Task { await store.load(silent: true) }
                }
                PhoneSync.shared.activate()
                if let stored = PhoneSync.stored {
                    store.station = stored.station
                    store.airportSelected = stored.airportSelected
                    store.selectionPhysical = stored.physical
                }
                // A position first, so the 3 NM airport rule can apply.
                await store.refreshLocation()
                await followOwnPositionIfAlone()
                if store.combined == nil { await store.load() }
                if barometerEnabled { barometer.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if barometerEnabled { barometer.start() }
                    guard store.combined != nil else { return }
                    Task {
                        await store.refreshLocation()
                        await followOwnPositionIfAlone()
                        if Date().timeIntervalSince(store.now) > Self.refreshAfter {
                            await store.load(silent: true)
                        }
                    }
                } else {
                    barometer.stop()
                }
            }
            .onChange(of: barometerEnabled) { _, on in
                if on { barometer.start() } else { barometer.stop() }
            }
            // Each fresh report from the field the wearer is at is a
            // calibration point; a remote station never is.
            .onChange(of: store.combined) { _, combined in
                guard let combined, store.selectionPhysical || store.atAirport,
                      let ref = combined.calibrationReference else { return }
                barometer.attemptCalibration(stationAltim: ref, tempC: combined.pressure.current.temp,
                                             observedAt: combined.observedSeries.last?.t)
            }
            // The complication shows the same local number, once a minute at most.
            .onChange(of: barometer.latestLocalAltim) { _, _ in
                guard let combined = store.combined, let r = barometer.lastLocalReading,
                      barometer.isCalibrated,
                      Date().timeIntervalSince(lastLocalSnapshotAt) > 60 else { return }
                lastLocalSnapshotAt = Date()
                var snap = TendencySnapshot(from: combined, updatedAt: store.now, atAirport: store.atAirport)
                snap.localDisplayHPa = combined.displayValue(fromLocalAltim: r.altim)
                snap.localAt = r.at
                SnapshotStore.save(snap)
            }
        }
    }

    /// With the phone out of reach and the selection "My location", the
    /// watch finds its own nearest station instead of the one the phone last
    /// sent. A cellular watch left behind still lands on the right field.
    private func followOwnPositionIfAlone() async {
        guard store.selectionPhysical, !PhoneSync.shared.isPhoneReachable else { return }
        let before = store.station
        await store.resolveStationFromLocation()
        if store.station != before { await store.load(silent: store.combined != nil) }
    }

    /// The local sensor reading in the station's kind of number, when it is
    /// calibrated and no older than the last report or an hour.
    private func localReading(_ combined: CombinedResponse) -> (value: Double, at: Date)? {
        guard barometerEnabled, barometer.isCalibrated || barometer.isProvisional,
              let r = barometer.lastLocalReading else { return nil }
        let lastMetar = combined.observedSeries.last?.t ?? .distantPast
        guard r.at >= lastMetar || store.now.timeIntervalSince(r.at) <= 3600 else { return nil }
        return (combined.displayValue(fromLocalAltim: r.altim), r.at)
    }

    @ViewBuilder
    private func loaded(_ combined: CombinedResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = combined.tendency {
                let head = combined.headlinePressure(atAirport: store.atAirport)
                let local = head?.isAltimeter == true ? nil : localReading(combined)
                HStack {
                    Image(systemName: t.cls.symbolName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(t.cls.color(intensity: t.intensity))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if let l = local {
                                Text("\(unit.format(l.value)) \(unit.label)")
                                    .font(.headline).monospacedDigit()
                                Circle().fill(.orange).frame(width: 6, height: 6)
                            } else if let h = head {
                                Text("\(unit.format(h.hPa)) \(unit.label)")
                                    .font(.headline).monospacedDigit()
                            }
                        }
                        // Unit is on the headline; the delta stays short so
                        // "altimeter" fits on the same line.
                        let lead = head?.isAltimeter == true ? "altimeter · " : (local != nil ? "sensor · " : "")
                        Text(lead + "\(deltaShort(t.delta3h)) · 3h")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                if backcountryEnabled, local != nil, let r = barometer.lastLocalReading {
                    // Off-field, Backcountry on: the setting to dial, marked as
                    // an estimate, and how fresh the calibration is.
                    Text("altimeter here \(unit.format(r.altim)) est." + calibrationAge)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            WatchChart6h(combined: combined, unit: unit, now: store.now)
                .frame(height: 82)
            Text(combined.verdict)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(freshness(combined))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private var calibrationAge: String {
        guard let at = barometer.calibratedAt else { return barometer.isProvisional ? " · rough" : "" }
        let m = max(0, Int(Date().timeIntervalSince(at) / 60))
        return m < 60 ? " · cal \(m) min ago" : " · cal \(m / 60) h ago"
    }

    private func deltaShort(_ hPa: Double) -> String {
        let v = unit.convertDelta(hPa)
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
        return "\(sign)\(String(format: unit == .hPa ? "%.1f" : "%.2f", abs(v)))"
    }

    /// "METAR 12 min ago", from the newest observation in the series.
    private func freshness(_ combined: CombinedResponse) -> String {
        let last = combined.observedSeries.last?.t ?? combined.pressure.cachedAt
        let m = max(0, Int(store.now.timeIntervalSince(last) / 60))
        return m < 60 ? "METAR \(m) min ago" : "METAR \(m / 60) h \(m % 60) min ago"
    }

    @ViewBuilder private var fallbackOrSpinner: some View {
        if let snap = SnapshotStore.load() {
            SnapshotMini(snapshot: snap, unit: unit)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private var fallbackOrError: some View {
        if let snap = SnapshotStore.load() {
            SnapshotMini(snapshot: snap, unit: unit)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                Button("Retry") { Task { await store.load() } }
            }
        }
    }
}

/// Tiny offline view backed by the last persisted snapshot.
private struct SnapshotMini: View {
    let snapshot: TendencySnapshot
    let unit: PressureUnit
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: snapshot.cls.symbolName)
                    .foregroundStyle(snapshot.cls.color(intensity: snapshot.intensity))
                if let p = snapshot.displayPressureHPa {
                    Text("\(unit.format(p)) \(unit.label)").font(.headline).monospacedDigit()
                }
            }
            Text(snapshot.verdict).font(.caption)
            Text("as of \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }
}

/// The phone chart's 6 h window, sized for a wrist: six hours observed
/// (slope-colored, like everywhere else in Barry), the next six from the
/// model dashed, a dot at now, hour ticks along the bottom and two pressure
/// labels on the right in the user's unit.
private struct WatchChart6h: View {
    let combined: CombinedResponse
    let unit: PressureUnit
    let now: Date

    private struct P: Identifiable {
        let id = UUID()
        let t: Date
        let v: Double    // converted for plotting
        let raw: Double  // hPa, for unit-independent slope
    }

    private var start: Date { now.addingTimeInterval(-6 * 3600) }
    private var end: Date { now.addingTimeInterval(6 * 3600) }

    private var observed: [P] {
        combined.observedSeries
            .filter { $0.t >= start && $0.t <= now }
            .compactMap { p in p.pressure.map { P(t: p.t, v: unit.convert($0), raw: $0) } }
    }

    /// Starts from the last observed point so the dashed line leaves the dot
    /// instead of appearing an hour later.
    private var forecast: [P] {
        let fc = combined.forecastSeries(after: now)
            .filter { $0.t <= end }
            .compactMap { h in h.pressure_msl.map { P(t: h.t, v: unit.convert($0), raw: $0) } }
        guard let last = observed.last, !fc.isEmpty else { return fc }
        return [P(t: last.t, v: last.v, raw: last.raw)] + fc
    }

    /// Pad the range so a calm day does not blow one hPa up to the full height.
    private var yDomain: ClosedRange<Double> {
        let vs = (observed + forecast).map(\.v)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        let minSpan = unit.convertDelta(3.0)
        let mid = (lo + hi) / 2
        let half = max((hi - lo) / 2, minSpan / 2) * 1.15
        return (mid - half)...(mid + half)
    }

    private var gradient: LinearGradient {
        let ps = observed
        guard ps.count >= 2, let first = ps.first?.t, let last = ps.last?.t, last > first else {
            return LinearGradient(colors: [TendencyClass.blueRamp(0)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        let times = ps.map(\.t)
        let raws = ps.map(\.raw)
        // Stops are placed on the full 12 h axis so the colour lines up with the points.
        let span = end.timeIntervalSince(start)
        let stops = ps.enumerated().map { i, p in
            let slope = PressureSlope.windowed(times: times, values: raws, at: i)
            return Gradient.Stop(color: TendencyClass.slopeColor(hPaPerHour: slope),
                                 location: min(1.0, max(0.0, p.t.timeIntervalSince(start) / span)))
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    private func label(_ v: Double) -> String {
        String(format: unit == .hPa ? "%.0f" : "%.2f", v)
    }

    var body: some View {
        Chart {
            ForEach(observed) { p in
                LineMark(x: .value("t", p.t), y: .value("p", p.v), series: .value("s", "obs"))
            }
            .foregroundStyle(gradient)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .interpolationMethod(.catmullRom)

            ForEach(forecast) { p in
                LineMark(x: .value("t", p.t), y: .value("p", p.v), series: .value("s", "fc"))
            }
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .interpolationMethod(.catmullRom)

            RuleMark(x: .value("now", now))
                .foregroundStyle(.tertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            if let last = observed.last {
                PointMark(x: .value("t", last.t), y: .value("p", last.v))
                    .foregroundStyle(.orange)
                    .symbolSize(24)
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour(), collisionResolution: .greedy)
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                if let v = value.as(Double.self) {
                    AxisValueLabel { Text(label(v)).font(.system(size: 9)).monospacedDigit() }
                }
            }
        }
    }
}
