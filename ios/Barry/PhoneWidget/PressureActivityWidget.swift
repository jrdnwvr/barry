//  PressureActivityWidget.swift
//  Barry — iPhone Widget
//
//  The lock-screen banner and Dynamic Island for a pressure event: the same
//  glyph, number, delta and verdict the app shows, and nothing else. Past
//  90 minutes without an update the "as of" leads and goes grey, so an old
//  activity never reads as live.

import ActivityKit
import SwiftUI
import WidgetKit

struct PressureActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PressureActivityAttributes.self) { context in
            PressureActivityBanner(context: context)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.trendSymbol)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(tint(context.state))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(valueLine(context.state))
                            .font(.headline).monospacedDigit()
                        Text(context.state.verdict)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.eventLabel)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.attributes.station) · \(asOf(context.state))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } compactLeading: {
                Image(systemName: context.state.trendSymbol)
                    .foregroundStyle(tint(context.state))
            } compactTrailing: {
                Text(deltaShort(context.state))
                    .font(.caption2.weight(.semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.trendSymbol)
                    .foregroundStyle(tint(context.state))
            }
        }
    }

    private func tint(_ s: PressureActivityAttributes.ContentState) -> Color {
        isStale(s) ? .gray : s.cls.color(intensity: max(0.35, s.intensity))
    }

    private func isStale(_ s: PressureActivityAttributes.ContentState) -> Bool {
        Date().timeIntervalSince(s.updatedAt) > 90 * 60
    }

    private func unit() -> PressureUnit {
        PressureUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "pressureUnit") ?? "") ?? .inHg
    }

    private func valueLine(_ s: PressureActivityAttributes.ContentState) -> String {
        let u = unit()
        let v = s.pressureHPa.map { "\(u.format($0)) \(u.label)" } ?? "—"
        return "\(v)   \(u.formatDelta(s.delta3h)) · 3h"
    }

    private func deltaShort(_ s: PressureActivityAttributes.ContentState) -> String {
        let u = unit()
        let d = u.convertDelta(s.delta3h)
        let sign = d > 0 ? "+" : (d < 0 ? "−" : "")
        return "\(sign)\(String(format: u == .hPa ? "%.1f" : "%.2f", abs(d)))"
    }

    private func asOf(_ s: PressureActivityAttributes.ContentState) -> String {
        "as of \(s.updatedAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct PressureActivityBanner: View {
    let context: ActivityViewContext<PressureActivityAttributes>
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }

    private var s: PressureActivityAttributes.ContentState { context.state }
    private var stale: Bool { Date().timeIntervalSince(s.updatedAt) > 90 * 60 }
    private var tint: Color { stale ? .gray : s.cls.color(intensity: max(0.6, s.intensity)) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: s.trendSymbol)
                .font(.title2.weight(.bold))
                .foregroundStyle(stale ? Color.gray : Color.primary)
                .frame(width: 30)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let p = s.pressureHPa {
                        Text("\(unit.format(p)) \(unit.label)")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).fixedSize()
                    }
                    Text("\(unit.formatDelta(s.delta3h)) · 3h")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 6)
                    Text(s.eventLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(s.verdict)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if stale {
                        Text("as of \(s.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Text("·")
                    }
                    Text(context.attributes.station + (s.isAltimeter ? " · altimeter" : ""))
                    if !stale {
                        Text("· as of \(s.updatedAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
    }
}
