# The radar timeline, six hours back and twelve ahead

Decided with Jordan 2026-10-02. What the radar's clock covers and where
each layer gets its picture for a time that is not now.

## Controls

`[6h] [60] [slider] [Now]`. The two replay chips pick the span and play it;
tapping the one that is playing pauses. Now parks on the newest observed
frame. The radar opens on the hour span and autoplays the last hour.

| Span | Frames | The loop |
|---|---|---|
| hour (`60`) | every ten minutes from two hours back, then the nowcast | the last hour |
| day (`6h`) | on the hour from six hours back, now, then on the hour to +12 h | the last six hours |

Forecast frames are scrubbed to, never looped.

## Where each layer's picture comes from

| Layer | Past | Ahead |
|---|---|---|
| Radar | MRMS frames (ten-minute for two hours, on the hour to six) | nowcast to 60 min where its score allows, then model reflectivity (HRRR REFC) to +12 h |
| Isobars, pressure shading | the station snapshots (every 25 min, 9.5 h kept) gridded as now | the field now plus the model's change from now (HRRR MSLP), so nothing jumps at now |
| Fronts, troughs, H and L | the last WPC analyses (three-hourly), blended | the analysis blended to the 12 and 24 h progs |
| Wind, stations, lightning, advisories, Change | now only | now only |

Layers that only know now stay drawn and the note line says so when the
clock is somewhere else.

## Server

- `/radar/frames?span=hour|day`. Without `span` the answer is what builds
  up to 93 expect (7 observed, 3 nowcast). Frames carry `kind`
  (observed, nowcast, model).
- `/radar/model/<key>/...png`: model reflectivity tiles, key = valid time
  plus the forecast hour, so a URL names one run.
- `/radar/pressure/series`: isobars (and the grid, with `grid=1`) for the
  day span's hours.
- `/fronts` gains `history`: the earlier analyses, oldest first.
- Nowcast frames are made to 60 minutes. Each lead is scored against the
  frame that arrives (CSI at 20 dBZ on the 0.04 degree copy, with
  persistence beside it) on `/models/scores`; leads past 30 minutes are
  listed only while the last three hours' score clears the bar.

## Model source

HRRR today. The reflectivity feed is a `FeedSpec` like the others, so the
RRFS switch is the same change as for the rest.
