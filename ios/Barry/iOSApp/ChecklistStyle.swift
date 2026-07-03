//  ChecklistStyle.swift
//  Barry — iOS
//
//  Design language borrowed from a Cessna pilot checklist (the N4670G reference):
//  flat color-coded section bars with a black nub and bold mono type, imperative
//  full-width directive banners, and dot-leader label→value rows. Aviation-utility
//  aesthetic: no gradients, no chrome, information first — color carries meaning.

import SwiftUI

// MARK: - Section bar

/// White-on-color section header bar with the checklist's left nub.
/// `CABIN` / `STARTING ENGINE` → `PRESSURE TREND` / `CONDITIONS`.
struct SectionBar: View {
    let title: String
    let color: Color
    /// Compact variant for sub-charts (wind/precip labels).
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.primary)
                .frame(width: 4)
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: compact ? 11 : 13, weight: .bold, design: .monospaced))
                    .kerning(1.1)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(color)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Directive banner

/// Full-width imperative banner — the checklist's "LAND STRAIGHT AHEAD" treatment,
/// used for Barry's verdict with the tendency color carrying severity.
struct DirectiveBanner: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(.headline, design: .default).weight(.bold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Dot-leader row

/// `Label . . . . . . . value` — the checklist's connective typography for
/// label/value pairs.
struct DotLeaderRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            LeaderDots()
                .frame(height: 10)
                .frame(minWidth: 12)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .layoutPriority(1)
        }
    }
}

private struct LeaderDots: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height * 0.7))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.7))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 4]))
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Section palette

/// The checklist's semantic colors, tuned for both light/dark backgrounds.
enum ChecklistPalette {
    /// Slate gray — preflight/ground sections ("CABIN", "NOSE").
    static let slate = Color(red: 0.42, green: 0.45, blue: 0.48)
    /// Teal — descent/conditions family.
    static let teal = Color(red: 0.28, green: 0.60, blue: 0.58)
    /// Blue — climb/precip family.
    static let blue = Color(red: 0.32, green: 0.55, blue: 0.78)
    /// Orange — engine/sensor family ("STARTING ENGINE").
    static let orange = Color(red: 0.85, green: 0.52, blue: 0.18)
}
