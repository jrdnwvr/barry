//  BarryPhoneWidget.swift
//  Barry — iPhone Widget
//
//  Lock-screen (accessory) + home-screen widget: the same glance the watch
//  complication gives, on the surfaces the phone is glanced at. Reuses the shared
//  self-fetching TendencyProvider, so the widget stays fresh on WidgetKit's budget
//  without the app being opened, and the same staleness rules apply.

import WidgetKit
import SwiftUI

@main
struct BarryPhoneWidgetBundle: WidgetBundle {
    var body: some Widget {
        BarryPhoneWidget()
    }
}

struct BarryPhoneWidget: Widget {
    let kind = "BarryPhoneWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TendencyProvider()) { entry in
            PhoneWidgetView(entry: entry)
        }
        .configurationDisplayName("Pressure Trend")
        .description("The 3-hour pressure trend and Barry's verdict.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular,
            .systemSmall,
        ])
    }
}
