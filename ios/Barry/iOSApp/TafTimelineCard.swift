//  TafTimelineCard.swift
//  Barry — iOS
//
//  The forecaster's own product as a timeline: flight category by the hour
//  for the next 24 hours, drawn like the rain and wind rows, with the night
//  shaded and sunset and sunrise marked. One sentence above it answers the
//  question the strip exists for: what category, until when. No header and
//  no legend: the sentence and the strip are the whole card. The model and
//  the strip live in Shared so the widget draws the same thing.

import SwiftUI

struct TafTimelineCard: View {
    let combined: CombinedResponse
    let now: Date

    var body: some View {
        if let tl = TafTimeline(combined: combined, now: now), !tl.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tl.sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                TafStrip(timeline: tl)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
