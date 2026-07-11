//  FrontWatchView.swift
//  Barry — iOS
//
//  The front watch. On a quiet day this renders NOTHING — the main screen owes
//  its calm to that rule. When the regional pressure field shows a coherent
//  pattern, one tappable banner appears between the hero and the chart; all the
//  depth (the station compass, the narrative, the honesty note) lives behind it
//  in a sheet. Direction comes from real station reports; timing comes from the
//  model trough — the copy keeps those two claims separate on purpose.

import SwiftUI

// MARK: - Banner (the only main-screen footprint)

struct FrontBanner: View {
    let front: FrontResponse
    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 10) {
                statusIcon
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(front.headline ?? "Front watch")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if let line = subline {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) { FrontDetailView(front: front) }
    }

    /// The arrow points the way the pattern is MOVING: toward us when it's
    /// approaching (falls bearing + 180), away when it has passed (falls bearing).
    @ViewBuilder private var statusIcon: some View {
        switch front.status {
        case "approaching":
            if let b = front.bearingDeg {
                Image(systemName: "arrow.up").rotationEffect(.degrees(b + 180))
            } else {
                Image(systemName: "arrow.down.forward")
            }
        case "passed":
            if let b = front.bearingDeg {
                Image(systemName: "arrow.up").rotationEffect(.degrees(b))
            } else {
                Image(systemName: "arrow.up.forward")
            }
        case "passing":
            Image(systemName: "arrow.down.circle")
        default: // forecast
            Image(systemName: "circle.dashed")
        }
    }

    private var subline: String? {
        switch front.status {
        case "approaching":
            if let eta = front.eta {
                return "Likely here around \(eta.formatted(date: .omitted, time: .shortened))"
            }
            return "Watch the next few hours"
        case "forecast":
            if let eta = front.eta {
                return "Around \(eta.formatted(date: .omitted, time: .shortened)), if the model has it right"
            }
            return nil
        case "passing":
            return "Happening now"
        case "passed":
            return "Moving away"
        default:
            return nil
        }
    }

    private var tint: Color {
        switch front.status {
        case "approaching", "passing":
            let fall = front.maxFall3h ?? front.ownDelta3h ?? -1.0
            return TendencyClass.classify(delta3h: fall)
                .color(intensity: TendencyIntensity.intensity(delta3h: fall))
        case "passed":
            return TendencyClass.rising.color(intensity: 0)
        default: // forecast: a maybe, styled like one
            return .secondary
        }
    }
}

// MARK: - Detail sheet

struct FrontDetailView: View {
    let front: FrontResponse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let h = front.headline {
                        Text(h).font(.title3.weight(.semibold))
                    }
                    if let d = front.detail {
                        Text(d)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let eta = front.eta,
                       front.status == "approaching" || front.status == "forecast" {
                        Label("Model puts the low point here around \(eta.formatted(date: .omitted, time: .shortened))",
                              systemImage: "clock")
                            .font(.subheadline)
                    }

                    if !front.stations.isEmpty {
                        FrontCompass(front: front)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 340)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        legend
                    }

                    Text("Direction comes from real pressure reports at the stations shown, each dot colored by its own last 3 hours. Timing comes from the model, and fronts often arrive sharper and a little earlier than the model draws them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .navigationTitle("Front watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(TendencyClass.fallingMod.color(intensity: 0.5), "falling")
            legendDot(TendencyClass.steady.color(intensity: 0), "steady")
            legendDot(TendencyClass.rising.color(intensity: 0), "rising")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}

// MARK: - Compass (the tendency field, drawn honestly)

/// Surrounding stations plotted by bearing and distance from the user's station
/// (center), each dot colored by its OWN 3h tendency — the raw pattern the
/// direction call was made from, so you can eyeball it yourself.
struct FrontCompass: View {
    let front: FrontResponse

    private var maxDistance: Double {
        max(front.stations.map(\.distanceKm).max() ?? 100, 50)
    }

    /// Label everything when sparse; past ~10 stations only the extremes get ids
    /// so the map stays readable (the dots still carry the pattern).
    private var labeledIDs: Set<String> {
        if front.stations.count <= 10 { return Set(front.stations.map(\.id)) }
        let byTendency = front.stations.sorted { abs($0.tendency3h) > abs($1.tendency3h) }
        return Set(byTendency.prefix(4).map(\.id))
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - 22

            ZStack {
                // Range rings: half and full extent, plus a north tick.
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                Circle()
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .frame(width: radius, height: radius)
                    .position(center)
                Text("N")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .position(x: center.x, y: center.y - radius - 10)
                Text("\(Int(maxDistance.rounded())) km")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .position(x: center.x + radius * 0.72, y: center.y + radius * 0.78)

                // The user's station, center stage.
                Circle()
                    .fill(Color.blue)
                    .frame(width: 11, height: 11)
                    .position(center)
                Text(front.station)
                    .font(.caption2.weight(.semibold))
                    .position(x: center.x, y: center.y + 14)

                // Ring stations by bearing/distance, colored by their own tendency.
                ForEach(front.stations) { s in
                    let angle = s.bearingDeg * .pi / 180
                    let r = (s.distanceKm / maxDistance) * radius
                    let pos = CGPoint(x: center.x + r * sin(angle),
                                      y: center.y - r * cos(angle))
                    Circle()
                        .fill(dotColor(s.tendency3h))
                        .frame(width: 9, height: 9)
                        .position(pos)
                    if labeledIDs.contains(s.id) {
                        Text(s.id)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .position(x: pos.x, y: pos.y + 11)
                    }
                }
            }
        }
    }

    private func dotColor(_ delta3h: Double) -> Color {
        TendencyClass.classify(delta3h: delta3h)
            .color(intensity: TendencyIntensity.intensity(delta3h: delta3h))
    }
}
