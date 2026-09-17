//  LightningBanner.swift
//  Barry — iOS
//
//  Lightning nearby as its own breakout card under the hero, in the slot
//  (and the shape) the front-watch banner used to own: a tinted rounded
//  card, a bolt in the icon column, the headline, a quieter second line,
//  and a chevron that opens the radar with the strikes on it. Only exists
//  while a fresh report or flash sits within 100 miles.

import SwiftUI

struct LightningBanner: View {
    let near: LightningNearby
    let now: Date
    /// Where the radar should open (the home station).
    let lat: Double
    let lon: Double
    let stationName: String
    var home: HomeMarker? = nil

    private var tint: Color { near.distanceMi < 3 ? .red : .orange }

    private var headline: String {
        let where_ = near.distanceMi < 3 ? "at the field" : "\(near.distanceMi) mi to the \(cardinalWord)"
        return "Lightning \(where_)"
    }

    private var cardinalWord: String {
        let words = ["N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
                     "S": "south", "SW": "southwest", "W": "west", "NW": "northwest"]
        return words[near.cardinal] ?? near.cardinal
    }

    /// "13 min ago, moving east · 98 flashes within 100 mi"
    private var subline: String {
        let m = max(0, Int(now.timeIntervalSince(near.at) / 60))
        var parts = [m < 1 ? "just now" : (m < 60 ? "\(m) min ago" : "\(m / 60) h \(m % 60) min ago")]
        if let d = near.detail(now: now) { parts.append(d) }
        var line = parts.joined(separator: ", ")
        if let n = near.flashes, n > 1 {
            line += " · \(n) flashes within 100 mi"
        } else if near.source == "metar" {
            line += " · reported by \(near.station)"
        }
        return line
    }

    var body: some View {
        NavigationLink {
            RadarScreen(lat: lat, lon: lon, stationName: stationName, home: home)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
