//  CategoryStripView.swift
//  Barry — iOS
//
//  The last six hours of flight category at the station as a row of colored
//  blocks (D2), with a one-phrase trend when ceiling or visibility moved.
//  Data is the METAR history already in /combined; nothing new is fetched.

import SwiftUI

struct CategoryStripView: View {
    let series: [SeriesPoint]
    let now: Date

    private static let hours = 6

    /// Category per hour slot, newest on the right; nil where nothing reported.
    private var slots: [String?] {
        (0..<Self.hours).reversed().map { back in
            let end = now.addingTimeInterval(-Double(back) * 3600)
            let start = end.addingTimeInterval(-3600)
            return series.last(where: { $0.t > start && $0.t <= end && $0.fltCat != nil })?.fltCat
        }
    }

    private var trendNote: String? {
        let recent = series.filter { $0.t >= now.addingTimeInterval(-3 * 3600) }
        guard let last = recent.last, let first = recent.first, first.t < last.t else { return nil }
        if let c1 = last.ceilingFt, let c0 = first.ceilingFt, c1 - c0 <= -500 {
            return "ceiling lowering"
        }
        if let c1 = last.ceilingFt, let c0 = first.ceilingFt, c1 - c0 >= 500 {
            return "ceiling lifting"
        }
        if let v1 = last.visibilitySM, let v0 = first.visibilitySM, v0 - v1 >= 2 {
            return "visibility dropping"
        }
        if let v1 = last.visibilitySM, let v0 = first.visibilitySM, v1 - v0 >= 2 {
            return "visibility improving"
        }
        return nil
    }

    var body: some View {
        let s = slots
        if s.compactMap({ $0 }).count >= 3 {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(Array(s.enumerated()), id: \.offset) { _, cat in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cat.map { FlightCategory.color($0) } ?? Color(.systemFill))
                            .frame(width: 14, height: 8)
                    }
                }
                Text("last \(Self.hours) h")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let note = trendNote {
                    Text("· \(note)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Flight category over the last \(Self.hours) hours: \(s.map { $0 ?? "no report" }.joined(separator: ", "))")
        }
    }
}
