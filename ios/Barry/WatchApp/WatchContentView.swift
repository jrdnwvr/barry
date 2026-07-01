//  WatchContentView.swift
//  Barry — watchOS
//
//  Condensed quick-look (brief §3, Phase 4): trend glyph, current value, 3h delta,
//  one-line verdict, and a compact sparkline. Fetches via the same backend; the
//  shared snapshot doubles as an offline fallback to respect rate limits.

import SwiftUI
import Charts

struct WatchContentView: View {
    @EnvironmentObject var store: PressureStore
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.hPa.rawValue
    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .hPa }

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task { if store.combined == nil { await store.load() } }
        }
    }

    @ViewBuilder
    private func loaded(_ combined: CombinedResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = combined.tendency {
                HStack {
                    Image(systemName: t.cls.symbolName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(t.cls.color(intensity: t.intensity))
                    VStack(alignment: .leading, spacing: 0) {
                        if let p = combined.currentPressure {
                            Text("\(unit.format(p)) \(unit.label)")
                                .font(.headline).monospacedDigit()
                        }
                        Text("\(unit.formatDelta(t.delta3h)) · 3h")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            WatchSparkline(combined: combined, unit: unit)
                .frame(height: 44)
            Text(combined.verdict)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
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
                if let p = snapshot.currentPressureHPa {
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

private struct WatchSparkline: View {
    let combined: CombinedResponse
    let unit: PressureUnit

    /// One line hop, pre-tinted by its rate of change (hPa/hour) — same coloring as
    /// the phone chart, via the shared TendencyClass.slopeColor.
    private struct Seg: Identifiable {
        let id: Int
        let t0: Date; let v0: Double
        let t1: Date; let v1: Double
        let color: Color
    }

    private var segments: [Seg] {
        // Keep raw hPa for the slope so coloring is unit-independent.
        let pts = combined.observedSeries.compactMap { p -> (Date, Double)? in
            p.pressure.map { (p.t, $0) }
        }
        guard pts.count >= 2 else { return [] }
        return (0..<(pts.count - 1)).map { i in
            let a = pts[i], b = pts[i + 1]
            let dt = b.0.timeIntervalSince(a.0) / 3600.0
            let slope = dt > 0 ? (b.1 - a.1) / dt : 0
            return Seg(id: i, t0: a.0, v0: unit.convert(a.1),
                       t1: b.0, v1: unit.convert(b.1),
                       color: TendencyClass.slopeColor(hPaPerHour: slope))
        }
    }

    var body: some View {
        Chart {
            ForEach(segments) { s in
                LineMark(x: .value("t", s.t0), y: .value("p", s.v0),
                         series: .value("seg", s.id))
                    .foregroundStyle(s.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                LineMark(x: .value("t", s.t1), y: .value("p", s.v1),
                         series: .value("seg", s.id))
                    .foregroundStyle(s.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
