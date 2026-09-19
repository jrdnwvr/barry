//  TafTimelineCard.swift
//  Barry — iOS
//
//  The forecaster's own product as a timeline: flight category by the hour
//  for the next 24 hours, drawn like the rain and wind rows, with the night
//  shaded and sunset and sunrise marked. One sentence above it answers the
//  question the strip exists for: what category, until when. The model and
//  the strip live in Shared so the widget draws the same thing.

import SwiftUI

struct TafTimelineCard: View {
    let combined: CombinedResponse
    let now: Date

    var body: some View {
        if let tl = TafTimeline(combined: combined, now: now), !tl.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Text("TAF")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let issued = tl.issueTime {
                        Text("issued \(issued.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(tl.sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                TafStrip(timeline: tl)
                if let caption = tl.hatchCaption {
                    Text(caption)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
