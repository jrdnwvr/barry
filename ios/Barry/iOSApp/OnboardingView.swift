//  OnboardingView.swift
//  Barry — iOS
//
//  First-run flow, shown once (hasOnboarded flag in the shared suite):
//    1. The thesis — change matters, not the number.
//    2. Where — use the phone's location and confirm the nearest station,
//       or pick an airport. The location prompt fires here, with the reason
//       on screen, never cold on the dashboard.
//    3. Units — pressure, wind, temperature; defaults follow the region and
//       write straight to the keys Settings uses.
//    4. Local readings opt-in — only on a device with a barometer; the
//       motion prompt fires at the tap.
//    5. Alerts opt-in — pressure changes and storms as separate switches,
//       plus the lock screen; permission is requested at the moment of intent.
//  Skip (bottom right, every page) bails out of the whole flow: marks
//  onboarding done, keeps defaults, enables nothing.

import CoreMotion
import SwiftUI
import UIKit

struct OnboardingView: View {
    @AppStorage("hasOnboarded", store: AppConfig.sharedDefaults)
    private var hasOnboarded: Bool = false
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.mph.rawValue
    @AppStorage(TemperatureUnit.key, store: AppConfig.sharedDefaults)
    private var tempUnitRaw: String = TemperatureUnit.celsius.rawValue
    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage(StormAlerter.enabledKey, store: AppConfig.sharedDefaults)
    private var stormAlertsEnabled: Bool = false
    @AppStorage(StormAlerter.pressureKey, store: AppConfig.sharedDefaults)
    private var pressureAlertsEnabled: Bool = false
    @AppStorage(LiveActivityManager.enabledKey, store: AppConfig.sharedDefaults)
    private var liveActivityEnabled: Bool = false
    /// The alerts page's own choices; written to the switches only on "Turn on".
    @State private var wantPressure = true
    @State private var wantStorms = true

    // The where page.
    @StateObject private var locations = SavedLocationsStore()
    @StateObject private var locator = LocationManager()
    private enum Where: Equatable {
        case idle, locating, found(String, String), noFix, airport(String, String)
    }
    @State private var whereState: Where = .idle
    @State private var showSearch = false
    @State private var airportQuery = ""
    @State private var matches: [StationSearchResult] = []

    @State private var page = 0

    private enum Page { case idea, use, whereAmI, units, sensor, alerts }
    private var hasBarometer: Bool { CMAltimeter.isRelativeAltitudeAvailable() }
    private var pages: [Page] {
        hasBarometer ? [.idea, .use, .whereAmI, .units, .sensor, .alerts] : [.idea, .use, .whereAmI, .units, .alerts]
    }

    /// What Barry is for, chosen on the second page; the where page's
    /// question follows it.
    @AppStorage(Audience.key, store: AppConfig.sharedDefaults)
    private var audienceRaw: String = ""
    private var audience: Audience? { Audience(rawValue: audienceRaw) }

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    pageView(p).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            bottomRow
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
        }
        // On iPad, full-bleed cards read stretched and the buttons get comically
        // wide — cap the flow to a phone-ish column, centered.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .onAppear(perform: seedUnits)
    }

    @ViewBuilder private func pageView(_ p: Page) -> some View {
        switch p {
        case .idea: ideaPage
        case .use: usePage
        case .whereAmI: wherePage
        case .units: unitsPage
        case .sensor: sensorPage
        case .alerts: alertsPage
        }
    }

    /// A fresh install starts on the region's units, knots for wind
    /// everywhere: that is what the tower says. Anything already chosen
    /// stays.
    private func seedUnits() {
        let d = AppConfig.sharedDefaults
        let us = Locale.current.measurementSystem == .us
        if d.object(forKey: "pressureUnit") == nil { unitRaw = (us ? PressureUnit.inHg : .hPa).rawValue }
        if d.object(forKey: "windUnit") == nil { windUnitRaw = (audience?.windUnit ?? .knots).rawValue }
        if d.object(forKey: TemperatureUnit.key) == nil {
            tempUnitRaw = (us ? TemperatureUnit.fahrenheit : .celsius).rawValue
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
            Text("The number says little. How fast it's moving says a lot. Barry watches that:")
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

    /// One tap: the choice sets the cards, the wind unit, the radar's
    /// layers and the rest, then moves on. Skipping it leaves the defaults.
    private var usePage: some View {
        pageLayout {
            Text("What will you use Barry for?")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(Audience.allCases) { a in
                    Button {
                        a.apply()
                        advance()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: a.icon)
                                .font(.body)
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            Text(a.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            if audience == a {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.use.\(a.rawValue)")
                }
            }
        } buttons: {
            EmptyView()
        }
    }

    private var whereTitle: String {
        switch audience {
        case .pilot, .soaring, .drone, .none: return "Where are you flying?"
        case .marine: return "Where are you on the water?"
        case .everyday, .weather: return "Where should Barry watch?"
        }
    }

    private var wherePage: some View {
        pageLayout {
            Image(systemName: "location")
                .font(.system(size: 30))
                .foregroundStyle(.blue)
            Text(whereTitle)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Barry reads the nearest reporting airport. Use your location, or pick an airport.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch whereState {
            case .idle:
                EmptyView()
            case .locating:
                ProgressView("Finding the nearest station")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .found(let id, let name):
                stationCard(label: "Nearest station", id: id, name: name)
            case .airport(let id, let name):
                stationCard(label: "Your airport", id: id, name: name)
            case .noFix:
                Text("No location fix. Pick an airport instead, or try again outside.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if showSearch {
                VStack(spacing: 0) {
                    TextField("Airport ID or name", text: $airportQuery)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("onboarding.airport")
                        .task(id: airportQuery) {
                            let q = airportQuery.trimmingCharacters(in: .whitespaces)
                            guard q.count >= 2 else { matches = []; return }
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            matches = (try? await BarryAPI().searchStations(q)) ?? []
                        }
                    ForEach(matches.prefix(4)) { m in
                        Button { choose(m) } label: {
                            HStack(spacing: 8) {
                                Text(m.station).font(.footnote.weight(.semibold)).monospaced()
                                Text(m.name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } buttons: {
            switch whereState {
            case .found, .airport:
                primaryButton("Continue") { advance() }
                ghostButton("Change") { whereState = .idle; showSearch = false; airportQuery = ""; matches = [] }
            default:
                primaryButton("Use my location") { locate() }
                if !showSearch {
                    ghostButton("Pick an airport") { showSearch = true }
                }
            }
        }
    }

    private func stationCard(label: String, id: String, name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(name.isEmpty ? id : "\(id) · \(name)")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One fix, the nearest station named, the selection set to "My location".
    private func locate() {
        whereState = .locating
        showSearch = false
        Task {
            guard let loc = await locator.requestLocation(timeout: 10) else {
                whereState = .noFix
                showSearch = true
                return
            }
            if let mine = locations.locations.first(where: { $0.isPhysical }) {
                locations.selectedID = mine.id
            }
            if let n = try? await BarryAPI().nearestStation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude) {
                AppConfig.sharedDefaults.set(n.station, forKey: AppConfig.syncStationKey)
                whereState = .found(n.station, n.name)
            } else {
                whereState = .found("Location set", "")
            }
        }
    }

    private func choose(_ m: StationSearchResult) {
        locations.add(SavedLocation(kind: .airport(icao: m.station)), select: true)
        AppConfig.sharedDefaults.set(m.station, forKey: AppConfig.syncStationKey)
        whereState = .airport(m.station, m.name)
        showSearch = false
        airportQuery = ""
        matches = []
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
                Text(windUnitRaw == WindUnit.knots.rawValue ? "knots, what the tower says" : " ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Temperature")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Temperature unit", selection: $tempUnitRaw) {
                    ForEach(TemperatureUnit.allCases) { u in
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
            Text(UIDevice.current.userInterfaceIdiom == .pad ? "Your iPad has a barometer" : "Your iPhone has a barometer")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Stations report about once an hour. Your phone's barometer reads every second, so changes show up sooner.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                checkRow("Live readings between station reports")
                checkRow("Calibrates itself, no setup")
                checkRow("Asks for motion access when you turn it on")
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
            Text("Get a heads-up")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Barry can check in the background and let you know.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                optionRow("Pressure changes",
                          "When it moves fast at your station. A sharp fall usually means weather on the way, a sharp rise gusty wind.",
                          isOn: $wantPressure)
                optionRow("Storms",
                          "Lightning within \(StormAlerter.lightningRangeMi) miles and heading your way, or thunderstorms likely in the next few hours.",
                          isOn: $wantStorms)
                optionRow("Lock screen",
                          "The trend as a Live Activity while a change is under way.",
                          isOn: $liveActivityEnabled)
            }
        } buttons: {
            if wantPressure || wantStorms {
                primaryButton("Turn on") {
                    pressureAlertsEnabled = wantPressure
                    stormAlertsEnabled = wantStorms
                    Task {
                        _ = await StormAlerter.requestAuthorization()
                        finish()
                    }
                }
                ghostButton("Not now, start Barry") { finish() }
            } else {
                primaryButton("Start Barry") { finish() }
            }
        }
    }

    private func optionRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                ForEach(0..<pages.count, id: \.self) { i in
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
