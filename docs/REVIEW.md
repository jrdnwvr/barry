# Ten-thousand-foot reviews

Every so often, step back and ask whether the app is still built for what
it is for. Each review is a dated section. Redo it before a public release
and whenever the feature registry (docs/FEATURES.md) has grown by a third.

## 2026-09-24

The app is for hyper-local, aviation-minded weather, made by a hobbyist for
hobbyists. This review asks four things: is the structure still right for
that, who else would use it and what would they need, is it customisable
enough, and does it look hand-made. It ends with a direction and a list of
things to fix first. It rests on the registry written the same day.

### What Barry is today

One idea and three rings. The idea is the pressure tendency: the three-hour
change, classified, worded, explained. Ring one is the field: category,
runway winds, TAF, density altitude, boundary layer, clouds, lightning.
Ring two is the sky: the radar and Aloft. Ring three is the sensors: the
phone's and the watch's barometers calibrated against the station.

By count: ten cards, two full-screen tools, five complication kinds, nine
widget kinds, a Live Activity, twenty-one backend routes, about fifty
settings keys, and 12,800 lines of Swift. Onboarding is five pages. There
is no usage telemetry, by design.

### Is it still set up for the use case?

At the centre, yes. The verdict, the chart, the alerts and the watch face
are the app, and they are the part nobody else has. Around it, three
things have drifted.

**The two halves compete for the top of the page.** The hero is pressure;
a pilot's first question is the field. The METAR strip at the very top is
the compromise, and it works, but the hero then stacks up to nine lines
under the number (freshness, altimeter tag, local compare, micro trend,
change badge, verdict, rate, explanation, low confidence) before the first
card. A pilot at an airport wants the field and the verdict in the first
screen; a person at home wants the verdict and the chart. Today both get
everything.

**Depth went into the sky before the field.** The radar has nine chips, a
More sheet, a key, an altitude rail and three notes. Aloft has five layers
and a level sheet. Meanwhile the field ring still knows one airport at a
time. Pilots fly between fields. There is no second field, no route, no
AIRMET, SIGMET or PIREP layer, and no icing or turbulence, all of which are
free from the Aviation Weather Center. The route and fields design
(docs/ROUTES.md) has been waiting since the 18th.

**Settings grew as a list of switches.** Fifty keys across Settings, the
Home screen page, the radar's More sheet and Aloft. Each one made sense on
the day. Together they serve the maker, who knows what every switch does,
more than a new user, who has to read them all. The card presets are the
right idea and stop at cards.

### Who else would use it

The tag letters match docs/FEATURES.md.

| Audience | Already works | Missing | Smallest change that would serve them |
|---|---|---|---|
| P, general aviation pilots | field strip, TAF, runway winds, density altitude, lightning, radar, Aloft, wind at altitude | a second field and a route; AIRMET, SIGMET and PIREPs on the map; icing and turbulence | build docs/ROUTES.md; add an advisories layer from AWC's public feeds |
| S, soaring and free flight | boundary layer, the ride line, Aloft, the altitude rail | cloud base from the spread, thermal strength and trigger time, a flyable window across the day, the wind gradient in words | a Soaring preset that puts Conditions and Aloft first, hides runways, and defaults the ceiling to 12k; a cloud base line on Conditions |
| D, drone operators | wind and gust, ceiling and visibility, storms, lightning | a plain "flyable now, next N hours" against wind at 400 ft (the 80 m wind is already in the feed), cloud clearance | a Drone preset that hides runways and density altitude and adds one line to the Wind card |
| M, marine | the tendency itself (the classic barometer use), storms, fronts, isobars, wind, the change field | buoys as stations (NDBC is public), marine forecast zones, gust and sea state, knots by default | a Marine preset; buoys once the station layer can take non-airport sources |
| E, everyday, and people who feel pressure changes | the verdict, the chart, pressure alerts split from storms, the watch face | settable thresholds (the alert fires at −3.0 hPa per 3 h; a migraine wants smaller), quiet hours, plain "big change coming" wording, no aviation jargon | an Everyday preset that hides the METAR strip, category colours, runways and TAF; a threshold slider on the alert |
| W, weather watchers | the radar's depth, fronts, isobars, the change field, the analysis card | height contours (planned), a national view, saved layer sets | radar layer presets (ROADMAP G6); height contours from docs/NOAA.md |
| B, backcountry | the Here card, estimates, the watch barometer | offline behaviour (last data cached and said so), the watch on its own, a trailhead altitude readout | cache the last `/combined` on the watch too; show "as of" everywhere when offline |

None of these needs new data except buoys and the AWC advisories, and both
are public. Most are a preset plus one line on an existing card.

### Customisation

What the user can set today: card order and visibility (with three
presets), three units, the wind card mode, the boundary layer reference,
the forecast card style, the radar's layers, styles and autoplay, the
Aloft ceiling and layers, two alert switches, the sensor, Backcountry, the
Live Activity, and saved locations.

What is fixed that should not be: the alert thresholds, the chart windows,
the radar's default layer set, which cards a preset means, the watch page,
which widgets exist, and the order of the hero's lines.

Three changes would make it feel customisable rather than configurable:

- **Presets by audience, asked once.** Onboarding's "Where are you
  flying?" becomes "What will you use Barry for?" with Pilot, Soaring,
  Drone, Marine, Everyday and Weather. A preset is a bundle of existing
  keys: cards, units, radar layers, ceiling, alert thresholds. Nothing new
  is stored. Editable afterwards in one place.
- **Settings on the card, not in the list.** A small gear on a card opens
  that card's own two or three options, writing the same keys. Settings
  shrinks to units, alerts, locations and the sensor.
- **Alert thresholds and quiet hours.** The one setting the everyday
  audience actually wants.

### Does it look hand-made?

The rule: made by a hobbyist, for hobbyists. Short, calm, one thought per
line, and white space. The tells of generated software are a caption
under every control, a pill on every line, a note for every empty state,
chips where a sentence would do, and a header row where none is needed.
Barry has some of each. From the inventory:

- **The hero.** Done the same evening. Was up to nine lines under the
  number; now the number, the badge, one quiet source line only at a field
  or on the phone sensor, the verdict, and one grey line of reasoning that
  rolls up. The two capsules, the chevron, the tap-to-compare, the
  "refreshed" time and the separate rate and confidence lines are gone.
- **The radar's bottom card.** Done the same evening. The chips sit behind
  a Layers button on the full screen as on the embed, the three notes are
  one line that is usually empty, the credit line moved to the key sheet
  and the Data sources card, and with Radar off the card disappears
  altogether.
- **Aloft.** A six-column header row, pills on every line ("BKN045 ·
  METAR", "0°C · 8,500 ft", "Boundary layer · 3,200 AGL", "ICING"), five
  chips plus a More menu, and a footer of sources. Drop the header row;
  the numbers explain themselves. Label the lines with a word, not a pill.
  Move the chips into the ceiling menu.
- **Settings.** A footer under every picker that restates the options.
  Four forecast card styles, which the code itself calls a testing
  artefact. Three Backcountry switches. The Live Activity toggle in three
  places. Cut the footers, pick two forecast styles, one Backcountry
  switch, one Live Activity switch.
- **Cards.** The Data sources card is a footer pretending to be a card.
  The chart's legend ("deeper = faster change · tap or drag to read")
  explains what the chart already shows. The card editor gives every card
  a one-line description.
- **Copy.** "Estimated, advisory only." and "For advisement only, not a
  replacement for PIREPs." read like a product's lawyer. The 91.121
  sentence belongs in the info sheet; the rest can go. "A card still only
  appears when it has something to show." is a maker's note, not a
  user's.
- **Where the white space went.** The hero, the Conditions card (six rows,
  each with a trend line), and the radar's bottom card. Each would read
  better with a third fewer lines.

What already looks right: the verdict, the TAF sentence, the summary
forecast's sentences, the runway sentence, the watch face, the lightning
card. Those are the voice. Make the rest match them.

### Where it should go

In order. Each step is small enough to ship on its own.

1. **Data independence.** docs/NOAA.md, already planned. Nothing else is
   safe to grow on the free tiers.
2. **The hand-made pass.** Thin the hero, the radar card, Aloft and
   Settings as above, and cull the forecast styles. Do this before adding
   surfaces, so new work copies the thinner pattern.
3. **Presets and card settings.** The onboarding question, the preset
   bundles, gears on the cards, thresholds and quiet hours.
4. **The second field and the route.** docs/ROUTES.md. Then the AWC
   advisories layer (AIRMET, SIGMET, PIREP) on the radar. Together these
   close the biggest gap for the primary audience, with free data.
5. **Height contours and dense winds.** NOAA phase 2, once the ingest
   exists.
6. **Buoys as stations.** The marine audience, once the station layer can
   take a non-airport source.

Keep out: NOTAMs and flight planning (that is ForeFlight's job), global
coverage, paid data, and anything whose cost scales with users.

### Fix first

Found by reading, not by users. Ordered by what a user would notice. All
eight were fixed the same day, along with the smaller items in the
registry; the list stays as the record of what the review caught.

1. The Troughs chip draws nothing unless Fronts and Front lines are on.
2. The small and lock-screen Pressure Trend widgets show the change in hPa
   beside an inHg label, and use sea-level pressure at an airport where
   every other surface shows the altimeter.
3. Background calibration runs for a selected remote airport, which the
   foreground path refuses because it corrupts the offset.
4. The observed-storm alert can post a raw `{eta}` placeholder.
5. The Data sources card can be hidden, removing the CC BY credit.
6. The phone overwrites the watch's barometer switch on every sync.
7. Three fallback paths call AWC outside the budget gate.
8. Key and options texts that disagree with the code (nowcast frame count,
   wind under 3 kt, the lightning window in three places).

### Measuring instead of guessing

There is no usage data and the privacy labels promise none. Before the
presets are designed, ask the Pilots group one question: which cards do
you keep on, and which did you turn off first. A screenshot of their
Home screen page is the whole answer. If that is not enough, count card
visibility on the phone and show it only to the user, never uploaded.

### Todo from this review

Checked off as each lands; the registry entry changes in the same commit.

Hand-made pass:
- [x] Hero: number, badge, one source line, verdict, one line of reasoning (090771a).
- [x] Radar card: chips behind a Layers button, one note line, credit moved to the key and the sources card (090771a).
- [x] Aloft: no header row, temperature and dew point as one METAR-style group, plain labels instead of pills, chips behind a Layers button, no sources footer, no "+24 h".
- [x] Settings: no footers under pickers, the five one-picker sections folded into one, one Backcountry switch, the Live Activity switch in Alerts only.
- [x] Home screen page, now "Cards": no card descriptions, no maker's-note footer.
- [ ] Forecast card styles: cull to two after the Pilots group has used them (Jordan's call, waits on tester feedback).
- [x] Cards: the Data sources card as a footer line, not a card; drop the chart legend line; the Conditions card a third shorter.
- [x] Copy: drop "Estimated, advisory only." and "For advisement only, not a replacement for PIREPs."; keep the 91.121 sentence in the info sheet.

Customisation:
- [x] Onboarding asks "What will you use Barry for?"; Pilot, Soaring, Drone, Marine, Everyday and Weather presets as bundles of existing keys, editable after ("Set up for" in Settings).
- [x] Each card's own options in a long-press menu with "Hide card" (no gear, so no new chrome). Settings keeps its "Cards and screens" rows for now so the options stay findable; dropping them is Jordan's call once testers find the menus.
- [x] Alert thresholds and quiet hours: "Alert on" fast, moderate or small changes; quiet hours deliver silently.

Audiences, smallest useful change each:
- [x] Soaring: a cloud base line on Conditions from the spread, with "blue thermals" when the layer tops out below it.
- [x] Drone: a line on the Wind card from the 80 m wind, now and the peak in the next six hours, shown when set up for drones. It reports rather than judges; a user-set limit could turn it into flyable or not later.
- [x] Everyday: a threshold on the pressure alert (a three-step picker rather than a slider; small is 1 hPa in 3 h).
- [x] Weather watchers: radar layer sets in Map options (Flying, Wind, On the water, Weather, Just the radar). Replaced 2026-09-25 by presets the user saves, with every layer also listed as a switch in Map options.
- [x] Backcountry: the watch opens on its own saved page with "as of" when offline, like the phone; widgets, complications and the Live Activity already said "as of".
- [x] Marine: NOAA buoys and coastal stations on the station layer (`/metars?buoys=1`), with waves, water temperature and the 3 h pressure change; on in the water preset.

Direction:
- [ ] Data independence, docs/NOAA.md phase by phase. Phase 0 done (weighted Open-Meteo budget, grids held for the model hour, last good grids). Phase 1 waits on Jordan: bridge first, or straight to NOAA (NOAA.md section 6).
- [x] The second field and the route (docs/ROUTES.md), then the AWC advisories layer. Fields card (every saved airport on one line, `/glance`); advisories layer (SIGMETs, G-AIRMETs, PIREPs on the radar, `/advisories`); the route (card, screen, planner, `/route`; still air, 15 NM corridor, no alternate).
- [ ] Height contours (NOAA phase 2).

Measuring:
- [ ] Ask the Pilots group for a screenshot of their Home screen page: which cards stay on.

Fix first: all eight fixed 2026-09-24 (2b4a0d2).

### How this review was made

Three sweeps read every Swift and Python source and wrote
docs/FEATURES.md. The review reads the registry, not the code, so anyone
can redo it. Run `python3 tools/check_features.py` first; it fails when a
settings key or a route is missing from the registry.
