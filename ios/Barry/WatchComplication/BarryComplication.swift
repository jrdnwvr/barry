//  BarryComplication.swift
//  Barry — Watch Complication
//
//  Widget definition + bundle. Renders the 3-hour tendency as icon + color depth
//  across the supported families (brief §4.1, §5): the tiny families get an
//  accessoryCircular gauge / accessoryCorner glyph; the larger inline & rectangular
//  families add the delta number.

import WidgetKit
import SwiftUI

@main
struct BarryComplicationBundle: WidgetBundle {
    var body: some Widget {
        BarryComplication()
        BarryDialComplication()
        BarryGraphComplication()
        BarryMetarComplication()
    }
}

struct BarryComplication: Widget {
    let kind = "BarryComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TendencyProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Pressure Trend")
        .description("The 3-hour pressure trend. Color deepens as pressure falls faster.")
        // Rectangular belongs to the dedicated Graph / METAR widgets now.
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
        ])
    }
}

/// Gauge-style dial: current pressure in the center, indicator angled by the
/// expected next-3h change. Circular family only.
struct BarryDialComplication: Widget {
    let kind = "BarryDialComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TendencyProvider()) { entry in
            DialComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Pressure Dial")
        .description("Current pressure on a dial, angled by the expected 3-hour change.")
        .supportedFamilies([.accessoryCircular])
    }
}
