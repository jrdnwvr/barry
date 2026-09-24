# Multiple fields and routes

Draft 2026-09-18. Not scheduled. Two pieces, both built on the saved
locations list that exists today, neither replacing it.

## 1. Fields card: the saved fields at a glance

Built 2026-09-24 (`iOSApp/FieldsCard.swift`, `/glance`). Answers to the
open questions below, as built: My location is not a row (only saved
airports); a long press on a row offers "Route to" that field; the card's
own menu is Hide card; the card lists up to eight fields and does not scroll. On by
default, shown only with two or more airports saved; hidden in the
drone, water, everyday and weather presets.

Today one saved field is selected at a time, switched through the menu
in the hero. The Fields card shows them all, one line each:

```
Fields
● KLUK   VFR   240@8    30.12 ↘   falling, front passing
● KI67   MVFR  040@5    30.19 →   steady
● KHAO   VFR   250@12   30.10 ↘   rain likely around 5 PM
```

- Category dot, wind, altimeter, trend arrow, a short form of the verdict.
- Tap a row to select that field (the same switch the hero menu does).
  The selected row is highlighted.
- A card in the Cards list. On by default only when two or more airports
  are saved. In the rail on iPad.
- Data: one new endpoint, `/glance?stations=KLUK,KI67,KHAO`, returning
  compact summaries from the cache. Saved fields are already watched
  stations, so the scheduler is already refreshing them. Cost scales with
  saved fields per user, not with users.

Open questions:
- Should "My location" appear as a row when it resolves to a field not in
  the list?
- Row tap selects; what does a long press do (route to, remove)?
- How many rows before the card scrolls or truncates?

## 2. Route: from X to Y

Built 2026-09-24 (`iOSApp/RouteViews.swift`, `backend/app/route.py`,
`/route`). Answers to the open questions below, as built: no alternate;
the corridor is 15 NM fixed (lightning counts within 30 NM); still air
only; one leg; nothing on the watch. The route screen draws the line on
a plain map rather than the radar, so the radar keeps one job; the
corridor stations carry their category colours. Arrival falls back to
the destination's current report ("MVFR now") when it has no TAF, rather
than to the model. On by default in the flying and soaring presets,
shown only while a route is set. Five recent pairs are kept.

A route is a departure and a destination, optionally an alternate, chosen
from saved fields or search, with a cruise speed from Settings (default
100 kt) for timing. Setting a route does not change the selected field:
the hero and the trend stay on the home station. It adds a Route card.

```
KLUK → KDAY          47 NM · 28 min · arrive 4:12 PM
Depart now   VFR   240@8   30.12   falling, front passing
Enroute      MVFR at KHAO · lightning 18 mi off the line · no fronts crossing
Arrive 4:12  VFR by TAF   270@12   30.08   52 min before sunset
```

**Depart** is the departure's current report and verdict.

**Enroute** is the worst category among reporting stations within about
15 NM of the straight line (from the bulk METAR table), lightning near
the corridor (from the flash store), and whether a WPC front crosses the
line. The corridor is a straight line, not an airway; the card says so.

**Arrive** is the destination at the arrival time: category from its TAF
at that hour (the TAF strip's own logic), the model where there is no
TAF, wind, altimeter, and the arrival relative to sunset.

Tapping the card opens a route screen: corridor stations in order with
distance along the line, and the radar centered on the route with the
line drawn, lightning and fronts already on it. One tap reverses the
route. Recent routes are kept.

**Where routes start:** "Route to" on a Fields row, "Plan a route" in
the hero's station menu, the empty Route card itself.

**Data:** `/route?from=KLUK&to=KDAY&speedKt=100` computed from data
already in memory (bulk table, flashes, fronts), plus the two endpoints
registered as watched stations. Cached per pair for five minutes. No new
upstream calls.

Open questions:
- Alternate: a third column, or a second route card?
- Corridor width: 15 NM fixed, or scaled with route length?
- ETA uses still air. Add the model's wind along the route once winds
  aloft exist (ROADMAP H and the AeroWeather notes), then fuel or time
  with wind.
- Multi-leg routes: out of scope until the two-field version has been
  flown with.
- Watch: the destination's row as a second page on the watch.

## Deliberately out for now

Winds aloft along the route, fuel, time with wind, airways, terrain. Each
belongs after the winds aloft row exists and after the go or no-go glance
above has been used for real.

## Effort

Backend endpoints about a day. Fields card half a day. Route card, screen
and map line a day and a half. The Fields card is useful on its own after
the first day and a half.
