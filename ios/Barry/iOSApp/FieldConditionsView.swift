//  FieldConditionsView.swift
//  Barry — iOS
//
//  Field conditions: density altitude now + where it's headed, and the fog
//  outlook for the coming night. The DA forecast is the takeoff-performance
//  decision made visible ("3,100 ft if you go at 9, 5,200 ft if you wait for
//  4 PM"); the fog line only exists on nights that actually have a setup —
//  quiet nights render nothing, same rule as the front watch.

import SwiftUI

struct FieldConditionsCard: View {
    let conditions: ConditionsOut

    private static let ftFormat: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func ft(_ v: Int) -> String {
        (Self.ftFormat.string(from: NSNumber(value: v)) ?? "\(v)") + " ft"
    }

    /// The highest forecast DA in the window — the number that decides whether
    /// to fly now or wait. Only worth a line when it's meaningfully above (or
    /// below) the current value.
    private var peak: DAPoint? {
        conditions.daForecast.max { $0.ft < $1.ft }
    }

    private var peakLine: (text: String, rising: Bool)? {
        guard let p = peak else { return nil }
        let time = p.t.formatted(date: .omitted, time: .shortened)
        if let now = conditions.densityAltitudeFt {
            if p.ft - now >= 300 {
                return ("Rising to \(ft(p.ft)) around \(time)", true)
            }
            if let low = conditions.daForecast.min(by: { $0.ft < $1.ft }),
               now - low.ft >= 300 {
                let lowTime = low.t.formatted(date: .omitted, time: .shortened)
                return ("Down to \(ft(low.ft)) by \(lowTime)", false)
            }
            return nil  // flat day: the current number is the story
        }
        return ("Around \(ft(p.ft)) at \(time)", true)
    }

    /// A station without temp/dew point (some AWOS fields) still gets the
    /// forecast DA; nothing at all means the card shouldn't exist.
    private var hasDA: Bool { conditions.densityAltitudeFt != nil || peak != nil }

    /// Where the boundary layer is headed over the next hours: the top of the
    /// bumpy, hazy air. Rising through the day is the normal story; the line
    /// only appears when it moves a real amount.
    private var blLine: (text: String, rising: Bool)? {
        guard let now = conditions.boundaryLayerFt else { return nil }
        let fc = conditions.blForecast
        guard let hi = fc.max(by: { $0.ft < $1.ft }), let lo = fc.min(by: { $0.ft < $1.ft }) else { return nil }
        if hi.ft - now >= 1000 {
            return ("Rising to \(ft(hi.ft)) around \(hi.t.formatted(date: .omitted, time: .shortened))", true)
        }
        if now - lo.ft >= 1000 {
            return ("Down to \(ft(lo.ft)) by \(lo.t.formatted(date: .omitted, time: .shortened))", false)
        }
        return nil
    }

    private func stormLine(_ st: StormOut) -> String {
        var line = st.risk == "likely" ? "Thunderstorms likely" : "Thunderstorms possible"
        if let s = st.start {
            line += st.risk == "likely" ? " from \(s.formatted(date: .omitted, time: .shortened))"
                                        : " around \(s.formatted(date: .omitted, time: .shortened))"
        }
        if st.risk == "likely", let e = st.end, let s = st.start, e > s {
            line += " to \(e.formatted(date: .omitted, time: .shortened))"
        }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasDA {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PerformanceAltitudeIcon()
                        .frame(height: 13)
                        .foregroundStyle(.blue)
                    Text("Density altitude")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let da = conditions.densityAltitudeFt {
                        Text(ft(da))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    } else if let p = peak {
                        Text("~\(ft(p.ft)) later")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                HStack {
                    if let elev = conditions.fieldElevationFt {
                        Text("Field \(ft(elev))")
                    } else if conditions.densityAltitudeFt == nil {
                        Text("No temperature in this station's report")
                    }
                    Spacer()
                    if let line = peakLine {
                        HStack(spacing: 3) {
                            Image(systemName: line.rising ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2.weight(.semibold))
                            Text(line.text)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let bl = conditions.boundaryLayerFt {
                if hasDA { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AirLayersIcon()
                        .frame(height: 12)
                        .foregroundStyle(.blue)
                    Text("Boundary layer top")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(ft(bl) + " AGL")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                HStack {
                    Text("Bumpy, hazy air mixes below it, smoother air above.")
                    Spacer()
                    if let line = blLine {
                        HStack(spacing: 3) {
                            Image(systemName: line.rising ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2.weight(.semibold))
                            Text(line.text)
                        }
                        .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let st = conditions.storm {
                if hasDA || conditions.boundaryLayerFt != nil { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cloud.bolt.fill")
                        .font(.subheadline)
                        .foregroundStyle(st.risk == "likely" ? .orange : .secondary)
                    Text(stormLine(st))
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(st.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fog = conditions.fog {
                if hasDA || conditions.boundaryLayerFt != nil || conditions.storm != nil { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cloud.fog.fill")
                        .font(.subheadline)
                        .foregroundStyle(fog.risk == "likely" ? .orange : .secondary)
                    Text(fogLine(fog))
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(fog.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func fogLine(_ fog: FogOut) -> String {
        var line = fog.risk == "likely" ? "Fog likely" : "Fog possible"
        if let onset = fog.onset {
            line += " from \(onset.formatted(date: .omitted, time: .shortened))"
        } else {
            line += " overnight"
        }
        if let clearing = fog.clearing {
            line += ", burning off around \(clearing.formatted(date: .omitted, time: .shortened))"
        }
        return line
    }
}
