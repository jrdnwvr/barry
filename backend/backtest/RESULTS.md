# Front watch backtest — results

One year of hourly replay (2025-07-01 to 2026-06-30), 30 stations within 240 km
of KLUK from the IEM ASOS archive, running the PRODUCTION algorithm
(`app.front`: same per-station deltas, same ring geometry, same plane fit).
Ground truth: pressure troughs at LUK detected with full hindsight on the
de-tided series (>= 2.0 hPa fall into the minimum over 12 h, >= 1.2 hPa rise
out over 9 h). Troughs with a >= 40 degree wind shift across them are tagged
"frontal" — those are the ones a pilot cares about.

Year totals: **168 troughs, 33 frontal**. Raw output: `results_full.txt`.
Reproduce: `fetch_iem.py` then `run_backtest.py` (data/ is gitignored).

## Detection

| signal | POD (all) | POD (frontal) | FAR | med. lead | duty cycle |
|---|---|---|---|---|---|
| production gates (grad 0.5, coh 0.3, fall -1.0) | 64% | **91%** | 48% | 9 h | 11.6% |
| baseline: own tendency <= -1.0 | 98% | 100% | 53% | 10 h | 23.8% |
| baseline: own tendency <= -1.5 | 90% | 91% | 45% | 9 h | 14.7% |

The sobering row is the last one: **a plain single-station rule (own 3 h fall
of 1.5 hPa — information the app already surfaces in the hero) matches the
regional gate's frontal POD at the same FAR and similar duty cycle, with much
higher overall POD.** The regional ring adds essentially no detection skill.
That is meteorologically coherent: isallobaric falls run hundreds of km ahead
of a trough, so the center's own barometer starts falling at about the same
time the ring shows a gradient.

Other detection findings:

- The coherence gate is nearly inert (0.20 vs 0.45 barely moves any number).
  Gradient is the only real lever, and it trades POD for duty almost linearly.
- FAR ~44-58% across the whole sweep — structural, not tunable. Autopsy: only
  43 of the 188 false episodes preceded a shallower (1.2-2.0 hPa) trough.
  Counting those as "sort of right", about 6 in 10 alerts precede a real
  pressure dip within 18 h; 4 in 10 precede nothing at the center.
- Requiring 2 h persistence guts POD (64% -> 30%): the gate flickers on real
  events too. Not a viable de-chattering fix.

## Direction

Scored against trough propagation direction fit to per-station arrival times
(only events where that fit is itself solid; 45 of 108 hits scoreable).

| estimator | median error, far out (first fire) | median error, close in (last fire) |
|---|---|---|
| plane-fit gradient (shipped) | **68 deg** | 131 deg |
| fall-centroid track (candidate v2) | 132 deg | **50 deg** |

The shipped gradient bearing is decent while the front is beyond the ring and
**flips to worse-than-random once the trough moves inside it** — the predicted
plane-fit failure mode, confirmed. The centroid tracker is its exact mirror
(useless far out, decent close in). The two are complementary regimes, which
is a design gift for v2: gradient bearing early, switch to centroid track once
the fall maximum is inside the ring. Neither alone deserves the compass arrow
at all ranges.

## Observational ETA (candidate)

Fall-centroid closing speed -> arrival time: n=13 qualifying fires, median
signed error **-5.8 h** (systematically early — the fall region leads the
trough itself, as theory says it must). Not usable. The model trough remains
the only defensible timing source.

## What this means for the shipped feature

1. **Detection is not the feature's value — direction and context are.** The
   hero's own tendency already detects as well or better. The banner earns its
   place by saying *which way* and *what pattern*, not *that* something comes.
2. **The bearing should not be trusted late.** Once the falls are strong at
   the center (the trough near or inside the ring), the gradient bearing is
   worse than saying nothing. Freeze or drop the direction claim late.
3. **Copy must own the ~50% miss rate.** "Usually brings the weather with it"
   overstates a 6-in-10 signal.
4. **Duty cycle at production gates is >1 episode/day** in an active year —
   too chatty for an alert, acceptable for a passive banner, wrong for
   notifications. Do not wire this to push alerts as-is.

## Limits of this backtest

One region (Ohio Valley), one year, one center station. Ground truth is
pressure troughs, not analyzed fronts. The direction truth is itself a noisy
fit. The replay computes the center's own delta with the same `_delta3h`
helper rather than the production tendency resolver, and no interpreter/
forecast runs here, so only the observational statuses were tested. Duty and
FAR would differ somewhat in drier climates (fewer mesoscale troughs).
