//  ForecastCaveatView.swift
//  Barry — iOS
//
//  The honest caveat (brief §4.3), now forecast-health-aware. Normal: a faint
//  "dashed line is forecast" note. Stale: the backend is re-serving its last good
//  forecast because the source is down — say so, with its age. Missing: the source
//  is down and there's nothing to re-serve — say that too, instead of letting the
//  dashed line silently vanish and look like a bug.

import SwiftUI

struct ForecastCaveatView: View {
    let combined: CombinedResponse
    let now: Date

    private enum ForecastHealth {
        case ok
        case stale(age: TimeInterval)
        case missing
    }

    private var health: ForecastHealth {
        guard let fc = combined.forecast else { return .missing }
        if fc.stale == true { return .stale(age: now.timeIntervalSince(fc.cachedAt)) }
        return .ok
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(degraded ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        .padding(.top, 2)
    }

    private var degraded: Bool {
        if case .ok = health { return false }
        return true
    }

    private var icon: String {
        if case .ok = health { return "info.circle" }
        return "exclamationmark.triangle"
    }

    private var text: String {
        switch health {
        case .ok:
            return "Dashed line is forecast."
        case .stale(let age):
            let hours = max(1, Int((age / 3600).rounded()))
            return "Forecast source is down. The dashed line is the last forecast, from about \(hours)h ago."
        case .missing:
            return "Forecast source is down right now, so this is station data only. It comes back on its own."
        }
    }
}
