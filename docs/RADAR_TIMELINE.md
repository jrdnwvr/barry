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
| day (`6h`) | every twenty minutes from six hours back, now, then on the hour to +12 h | the last six hours |

Forecast frames are scrubbed to, never looped: the animation is the past
only (Jordan, 2026-10-02), and no front is drawn ahead of its last chart.

A loop is a clock running evenly through the weather, not a walk through
frames. A loop buffers first: the map holds on the newest frame until the
loop's frames are loaded for the view, then plays. The radar shows the
frame nearest the clock and crossfades; the isobars are drawn for the
clock's own moment thirty times a second, so they glide. The fronts and
the pressure centres are the WPC chart of that moment, crossfading to the
next: sliding them between charts was tried and flew them across the map,
because WPC redraws and re-segments every front on every chart. Over six hours the isobars
are the field's shape with the area-wide rise or fall taken out, unlabelled:
the true lines of a flat field that is rising everywhere march across the
map and, when the loop goes round, look like a belt. Those lines are drawn
by the GPU from the pressure grids (`IsolineView`): the tiled renderer broke
a moving line at its tile edges. What a Metal radar would add
(rain sliding along its motion instead of crossfading) is not built: it
has to sit above Apple's labels. To be judged against this.

## Where each layer's picture comes from

| Layer | Past | Ahead |
|---|---|---|
| Radar | MRMS frames (ten-minute for two hours, twenty-minute to six) | nowcast to 60 min where its score allows, then model reflectivity (HRRR REFC) to +12 h |
| Isobars, pressure shading | the station snapshots (every 25 min, 9.5 h kept) gridded as now, an hour apart, slid together and contoured on the phone for the moments between | the field now plus the model's change from now (HRRR MSLP), so nothing jumps at now |
| Fronts, troughs, H and L | the WPC analysis that was current then (three-hourly), crossfading to the next | the forecast chart (12 and 24 h progs) once past half way to it |
| Wind, stations, lightning, advisories, Change | now only | now only |

Layers that only know now stay drawn and the note line says so when the
clock is somewhere else.

## Server

- `/radar/frames?span=hour|day`. Without `span` the answer is what builds
  up to 93 expect (7 observed, 3 nowcast). Frames carry `kind`
  (observed, nowcast, model).
- `/radar/model/<key>/...png`: model reflectivity tiles, key = valid time
  plus the forecast hour, so a URL names one run.
- `/radar/pressure/series`: the pressure field gridded at the day span's
  hours and at now, on one lattice; the app contours it.
- `/fronts` gains `history`: the earlier analyses, oldest first.
- Nowcast frames are made to 60 minutes. Each lead is scored against the
  frame that arrives (CSI at 20 dBZ on the 0.04 degree copy, with
  persistence beside it) on `/models/scores`; leads past 30 minutes are
  listed only while the last three hours' score clears the bar.

## Model source

HRRR today. The reflectivity feed is a `FeedSpec` like the others, so the
RRFS switch is the same change as for the rest.
