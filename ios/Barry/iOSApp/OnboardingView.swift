//  OnboardingView.swift
//  Barry — iOS
//
//  First-run flow, shown once (hasOnboarded flag in the shared suite):
//    1. The thesis — change matters, not the number.
//    2. Units — writes straight to the same keys Settings uses.
//    3. Local readings opt-in — sets phoneBarometerEnabled; iOS permission
//       prompts then fire naturally when the sensor starts.
//    4. Storm alerts opt-in — flips the flag and requests notification
//       permission right at the moment of stated intent.
//  Skip (bottom right, every page) bails out of the whole flow: marks
//  onboarding done, keeps defaults, enables nothing. The ghost buttons on
//  pages 3/4 decline just that feature and keep going.

import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasOnboarded", store: AppConfig.sharedDefaults)
    private var hasOnboarded: Bool = false
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.mph.rawValue
    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage(StormAlerter.enabledKey, store: AppConfig.sharedDefaults)
    private var stormAlertsEnabled: Bool = false

    @State private var page = 0
    private let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(page + 1) of \(pageCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            TabView(selection: $page) {
                ideaPage.tag(0)
                unitsPage.tag(1)
                sensorPage.tag(2)
                alertsPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            bottomRow
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Pages

    private var ideaPage: some View {
        pageLayout {
            TrendCurveGraphic()
                .frame(height: 90)
                .padding(.horizontal, 24)
            Text("It's the change, not the number")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("The pressure reading by itself doesn't tell you much. How fast it's moving does. Barry watches that and gives you a straight answer:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Pressure falling. Rain likely around 5 PM.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(red: 0.52, green: 0.33, blue: 0.03))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(TendencyClass.amberToRed(0).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 8))
        } buttons: {
            primaryButton("Continue") { advance() }
        }
    }

    private var unitsPage: some View {
        pageLayout {
            Text("Pick your units")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Pressure unit", selection: $unitRaw) {
                    ForEach(PressureUnit.allCases) { u in
                        Text(u.label).tag(u.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(unitRaw == PressureUnit.inHg.rawValue
                     ? "inches of mercury, used in US aviation"
                     : "hectopascals, the metric standard")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Wind")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Wind unit", selection: $windUnitRaw) {
                    ForEach(WindUnit.allCases) { u in
                        Text(u.label).tag(u.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text("You can change these later in settings")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } buttons: {
            primaryButton("Continue") { advance() }
        }
    }

    private var sensorPage: some View {
        pageLayout {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Your iPhone has a barometer")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Weather stations only report about once an hour. Your phone can read pressure every second. Barry uses it to fill in the gaps and catch changes sooner.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                checkRow("Live readings between station reports")
                checkRow("Calibrates itself, no setup")
                checkRow("Needs motion and location access")
            }
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        } buttons: {
            primaryButton("Turn on local readings") {
                phoneBarometerEnabled = true
                advance()
            }
            ghostButton("Not right now") { advance() }
        }
    }

    private var alertsPage: some View {
        pageLayout {
            Image(systemName: "bell")
                .font(.system(size: 30))
                .foregroundStyle(.blue)
            Text("Barry can watch for storms")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("If the pressure starts moving fast, Barry can send you a notification. A big drop usually means a storm is coming. A sharp rise can mean gusty wind.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pressure dropping fast")
                    .font(.footnote.weight(.semibold))
                Text("Down 3.2 hPa in 3h at your station. Storm may be approaching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
            Text("It checks in the background. It won't drain your battery.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } buttons: {
            primaryButton("Turn on storm alerts") {
                stormAlertsEnabled = true
                Task {
                    _ = await StormAlerter.requestAuthorization()
                    finish()
                }
            }
            ghostButton("Not now, start Barry") { finish() }
        }
    }

    // MARK: - Shared layout pieces

    private func pageLayout<Content: View, Buttons: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()
            content()
            Spacer()
            buttons()
        }
        .padding(.horizontal, 28)
    }

    private func checkRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var bottomRow: some View {
        HStack {
            // Balance the Skip label so the dots stay centered.
            Text("Skip").opacity(0)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.primary : Color(.systemGray4))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button("Skip") { finish() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    // MARK: - Flow

    private func advance() {
        withAnimation(.snappy(duration: 0.25)) { page += 1 }
    }

    private func finish() {
        hasOnboarded = true
    }
}

/// The thesis in one picture: a gentle drift steepening into a deep-blue fall,
/// using the same blue ramp the real chart uses.
private struct TrendCurveGraphic: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.25))
                    p.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.42),
                                   control: CGPoint(x: w * 0.24, y: h * 0.27))
                }
                .stroke(TendencyClass.blueRamp(0.12),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: w * 0.42, y: h * 0.42))
                    p.addQuadCurve(to: CGPoint(x: w, y: h * 0.95),
                                   control: CGPoint(x: w * 0.74, y: h * 0.55))
                }
                .stroke(TendencyClass.blueRamp(0.95),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle()
                    .fill(TendencyClass.blueRamp(0.5))
                    .frame(width: 12, height: 12)
                    .position(x: w * 0.42, y: h * 0.42)
            }
        }
    }
}
