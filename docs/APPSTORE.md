# App Store readiness

What to enter and check before the public release. Written 2026-09-22 to
match the privacy page (`/privacy`) and the manifests in the four targets.

## Privacy nutrition labels (App Store Connect → App Privacy)

Data collected, all **not linked to the user** and **not used for tracking**:

| Data type | Category | Purpose | Why |
|---|---|---|---|
| Precise Location | Location | App Functionality | sent with the request for the nearest station and the forecast; not stored beyond the server's cache |
| Crash Data | Diagnostics | App Functionality | MetricKit reports to `/diagnostics` |
| Performance Data | Diagnostics | App Functionality | launch times, hangs and battery from the same reports |

Nothing else. No identifiers, no contact info, no usage data, no
purchases. "Data Not Collected" is wrong now that diagnostics ship; pick
the three above.

The privacy policy URL is `https://barry.wide-stack.com/privacy` and the
support URL is `https://barry.wide-stack.com/support`.

## Privacy manifests

`PrivacyInfo.xcprivacy` sits in the app, the widget, the watch app and the
complication. Tracking off, no tracking domains. Collected types match the
table above (the widget and complication collect nothing themselves). The
one required-reason API is UserDefaults, reasons CA92.1 (the app's own)
and 1C8F.1 (the app group shared with its extensions).

## Before submitting

- Xcode Cloud: the scheme carries BarryTests and BarryUITests; turn the
  Test action on in both workflows so a red test fails the build. The UI
  test needs a simulator with network access; if the cloud image cannot
  reach the backend, keep it out of the cloud and run it locally.
- A real phone on the radar for an hour: pan, zoom, every layer, then
  leave it a day so MetricKit sends its first report and a file appears in
  `backend/state/diagnostics/`.
- Courtesy emails to RainViewer and Iowa Mesonet (drafted).
- Listing copy and screenshots; read the support page on a phone.
- Keep the Pilots group as the release gate.
