# Barry — iOS / watchOS

SwiftUI app (iOS 17+), watch app (watchOS 10+), and a WidgetKit complication. All
three targets share the `Shared/` folder (models, networking, tendency logic).

## Generate & open the project

The `.xcodeproj` is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonyz/XcodeGen) so the project file isn't checked in
and source membership stays declarative:

```bash
brew install xcodegen      # once
cd ios
xcodegen generate
open Barry.xcodeproj
```

## Build (verified)

This scaffold compiles and links cleanly. The whole stack builds for the simulator
without signing:

```bash
cd ios
xcodegen generate
xcodebuild -project Barry.xcodeproj -scheme Barry \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
# => ** BUILD SUCCEEDED **  (iOS app embeds the watch app, which embeds the
#    complication .appex — all three targets compile)
```

## Before running on a device

1. **Backend:** start it (`cd ../backend && .venv/bin/uvicorn app.main:app --port 8077`).
   In the three `Info.plist` files, set `BarryBackendURL` to your Mac's LAN IP
   (e.g. `http://192.168.1.20:8077`) — `127.0.0.1` on the device means the device
   itself. For release, deploy the backend over HTTPS at `https://barry.wide-stack.com`,
   set that as `BarryBackendURL`, and drop the `NSAllowsLocalNetworking` ATS exception.
2. **Signing:** set `DEVELOPMENT_TEAM` in `project.yml` (or pick your team per
   target in Xcode → Signing & Capabilities), then re-run `xcodegen generate`.
3. **App Group:** all three targets declare `group.me.wvr.barry` (see the
   `.entitlements` files). Change it to your own group id in those three files +
   `Shared/AppConfig.swift`, and enable the App Group capability for each target in
   your developer account. This is how the complication reads the last-known
   tendency snapshot the app writes.
4. **Simulator caveat:** the simulator gives no real barometer — but this app gets
   pressure from the backend, not the sensor, so the simulator is fully functional
   against a running backend.

## Layout & phase mapping

| Folder | Phase | Contents |
|--------|-------|----------|
| `Shared/` | 3–5 | `Models`, `BarryAPI`, `Tendency` (mirrors backend §4.1), `PressureUnit`, `PressureStore`, `LocationManager`, `SharedSnapshot` (App Group bridge), `AppConfig` |
| `iOSApp/` | 3, 6 | `ContentView`, `PressureChartView` (hero −24/+24 curve), `VerdictHeaderView`, `ConfirmationOverlayView` (wind/precip), `ForecastCaveatView`, `SettingsView` (station, hPa/inHg) |
| `WatchApp/` | 4 | `WatchContentView` — condensed glyph + value + 3h delta + verdict + sparkline, with offline snapshot fallback |
| `WatchComplication/` | 5 | `TendencyProvider` (timeline), `ComplicationViews` (circular/corner/inline/rectangular), color-intensity per §4.1 |

## Notes

- **Tendency thresholds live in two places** by design: `backend/app/tendency.py`
  and `Shared/Tendency.swift`. They're a tiny, stable table — keep them in sync by
  hand. The intensity-mapping note (prose vs. example JSON) applies on both sides.
- **Complication refresh** is requested every ~20 min (`TendencyProvider`); watchOS
  budgets background updates, so it's not live. The app calls
  `WidgetCenter.reloadAllTimelines()` after each fetch to push fresh data sooner.
- **Not yet wired:** push notifications on `falling_fast` crossings, multiple saved
  stations, and the iOS `CMAltimeter` live-pressure enrichment dot (brief §8
  nice-to-haves).
