//  ForecastCaveatView.swift
//  Barry — iOS
//
//  The honest caveat (brief §4.3): forecast pressure is smoothed; real fronts often
//  arrive sharper than the model's clean dip. Keep it faint so it informs without
//  alarming.

import SwiftUI

struct ForecastCaveatView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text("Dashed line is forecast — actual fronts may arrive sharper than the model shows.")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
}
