# Home screen widgets

Written 2026-09-19. Widgets are opt-in by nature, so they are where the
pilot-specific cards can live without adding anything to the screen inside
the app. Every widget below is a card the app already draws, so each one is a
data question and a layout, not a feature.

Status 2026-09-19: TAF, field glance, trend medium, and runway winds built
(`PhoneWidget/CardWidgets.swift`, `CombinedProvider.swift`); shared pieces
moved to `Shared/` (FlightCategory, RunwayMath, RunwayWindDial, TafTimeline,
TafStrip, CombinedStore). Verified on the simulator with real data.

## How they get data

One provider for all of them, `CombinedProvider` in the phone widget
extension. The app saves the last `/combined` payload it fetched to the App
Group container (`CombinedStore`) on every load; the provider reads that file
and answers at once, then refreshes behind it when the file is older than 15
minutes and asks WidgetKit to redraw when the fetch lands. A widget only
waits on the network when there is no file at all, and then for eight
seconds at most. The station is the one the app last showed. The airport
rule (altimeter setting versus sea-level pressure) comes from the snapshot
the app already writes for the complications.

Staleness is honest everywhere: past two hours without a refresh the widget
says "as of" with the time and drops its colors to grey, the same rule as the
watch complications.

## The widgets

### TAF (medium, and the lock screen)

The TAF card as it is in the app: the sentence ("VFR until 2 AM, then MVFR,
LIFR by 4 AM") above the 24 hour strip of category runs, night washed
behind, sunset and sunrise marked with their times, TEMPO and PROB hatched,
a bust noted first when the METAR disagrees with the TAF for this hour.
Station and issue time in the header.

- Medium: sentence, strip, station, issued time.
- Lock screen rectangular: station, the sentence on two lines, a thin
  version of the strip.
- Lock screen inline: "KLUK VFR until 2 AM, then MVFR".
- No TAF at the station: "No TAF for KI67" and the nearest field with one
  is a later improvement.
- Refresh: TAFs issue every six hours; the 15 minute cadence is more than
  enough.

### Field glance (small and medium)

The METAR strip from the top of the app and the watch METAR complication,
on the phone.

- Small: station, category in its color, wind in TAF shorthand ("160@7"),
  altimeter setting.
- Medium: the small row, then visibility, ceiling with cover, density
  altitude and field elevation, temperature and dew point, report age.
- Category color rules: the observed category, derived from ceiling and
  visibility when the station does not report one (marked with a small
  dot, as on the map).
- Calm wind shows "calm"; missing fields are left out rather than shown as
  dashes.

### Trend (medium)

The small trend widget exists (glyph, value, verdict). The medium is the
Graph complication scaled up: value and 3 h delta on the left with the
verdict under them, the last 12 hours as the slope-colored line on the
right with a dot at now and the dashed model tail. When lightning is within
100 miles, one line replaces the verdict's second line: "Lightning 29 mi
north, moving east". Most days that line is absent; the widget never shows
an empty lightning state.

### Runway winds (small)

The runway dial: the rose, the best runway drawn to its real heading, the
wind barb on the ring, and under it "Rwy 21L · 9 kt from the right". Follows
the app's runway winds setting: Runway shows components whenever the field
has runway data, Auto only at an airport, Compass never. Without runway data
or in Compass mode it is the wind on the rose with "160 at 7 kt". Calm wind
shows the open circle and "calm".

## Lower priority, not built yet

- **Rain and wind.** The next hours' precipitation and wind from the model.
  Apple Weather covers this well; low differentiation.
- **Fields at a glance.** Waits on the Fields card in docs/ROUTES.md. Once it
  exists, a medium widget with one line per saved field will be the best of
  the set for anyone with more than one field.
- **Radar.** A widget can only show a rendered image, and composing tiles
  and overlays inside the widget's time budget is a project on its own.
- **Here (off-field).** Needs the phone's position and sensor, which a widget
  does not have.

## Order

TAF, field glance, trend medium, runway winds. About half a day each. Shared
code moved out of the app target so the extension can draw the same views:
the flight category colors, the runway wind math and dial, the TAF timeline
model and strip.
