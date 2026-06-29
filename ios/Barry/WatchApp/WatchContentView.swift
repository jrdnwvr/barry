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

    var body: some View {
        let obs = combined.observedSeries.compactMap { p -> (Date, Double)? in
            p.pressure.map { (p.t, unit.convert($0)) }
        }
        Chart {
            ForEach(Array(obs.enumerated()), id: \.offset) { _, pt in
                LineMark(x: .value("t", pt.0), y: .value("p", pt.1))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}
