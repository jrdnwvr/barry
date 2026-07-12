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

## v1.1 — changes shipped from these findings

Gate: "approaching" now REQUIRES the center's own tendency falling
(own <= -0.3 hPa/3h) on top of the regional pattern, and coherence left the
detection gate (it filtered nothing). Verified on the same year:

| gate | POD (all) | POD (frontal) | FAR | lead | duty |
|---|---|---|---|---|---|
| v1 (as first shipped) | 64% | 91% | 48% | 9 h | 11.6% |
| v1.1 (own fall required) | 61% | **91%** | **45%** | 9 h | **10.0%** |

Every frontal hit kept, ~50 fewer episodes a year. Detection now belongs to
the hero by construction; the ring only explains a fall already on screen.

Direction: switching rules were tried against the same samples (see
`results_full.txt`). Coherence-as-regime-detector failed (86-88 deg); the
agreement blend was accurate (60 deg) but silent 60% of the time. Shipped:
**centroid track when the fall pattern's motion is measurable (two epochs from
one hours=8 bbox fetch), gradient as fallback only while the plane fit is
coherent, otherwise the banner says the direction isn't clear.** Measured 71
deg median with statements >90 deg wrong cut from 49% to 38% — roughly
quadrant precision, so the copy says "roughly" and the "passed" status points
at the fall centroid's position rather than a plane fit.

ETA: unchanged (model trough). The observational candidate stays rejected.

Copy: the detail sentence now carries the measured odds ("roughly six of ten
patterns like this brought a real pressure dip within a day").

Policy, encoded in front.py's docstring: front statuses never feed
notifications — banner-grade evidence only.

## Multi-region validation and v1.2

Four regions were added, picked to stress the assumptions, not flatter them:
FTW (southern plains drylines/convection), BFI (Puget Sound — marine systems
off an ocean with no stations, so the ring is one-sided), FCM (upper-Midwest
frontal parade), DVT (Sonoran desert heat lows + monsoon). Same year, same
method, ~30 stations each. Run: `run_backtest.py LUK FTW BFI FCM DVT`.

Surprises, both directions:
- **Phoenix did NOT false-alarm-explode.** The predicted heat-low failure mode
  produced the LOWEST FAR of all five regions (28-35%) — desert falls that
  clear the gates mostly precede real (monsoon/outflow) troughs.
- **Seattle's one-sided ring works.** 88-100% frontal POD, and the ring
  genuinely beats the single-station baseline there (which manages only 76%
  frontal) — the one region where the spatial field adds detection skill.
- **Fort Worth broke the v1.1 gradient gate**: sharp mesoscale troughs fit to
  a weak plane over 240 km, so MIN_GRADIENT 0.5 missed a quarter of frontal
  events the single-station baseline caught.

**v1.2 (shipped):** MIN_GRADIENT 0.5 -> 0.3, MIN_FALL -1.0 -> -1.5 (the deeper
required fall buys back the FAR/duty the lower gradient bar would cost),
OWN_FALL_MAX -0.3 -> -0.5. Chosen from a 12-cell grid over all five regions:

| region | frontal POD v1.1 -> v1.2 | FAR | duty | lead |
|---|---|---|---|---|
| LUK | 91% -> **97%** | 45 -> 49% | 10.0 -> 14.7% | 9 -> 10 h |
| FTW | 76% -> **91%** | 54 -> 47% | 8.5 -> 13.4% | 8 h |
| BFI | 88% -> **100%** | 43 -> 43% | 11.1 -> 16.4% | 9 h |
| FCM | 85% -> **89%** | 55 -> 55% | 16.9 -> 19.1% | 10 h |
| DVT | 81% -> **98%** | 28 -> 35% | 8.9 -> 17.0% | 6 -> 8 h |

Mean frontal POD 84% -> 95% at flat FAR; the cost is duty (banner up ~15% of
hours in an active year vs ~11%) — acceptable for a passive banner that only
ever appears while the hero already shows falling, and still never wired to
notifications.

**Direction, per region (shipped rule):** median 50-86 deg, statements more
than a quadrant wrong 31-48%. It is climate-dependent: solid where systems are
synoptic and translate cleanly (FCM 50 deg, BFI 60 deg, LUK 70 deg), weak
where the weather is mesoscale/convective (FTW 81 deg, DVT 86 deg) — though in
those regions the ground-truth propagation fit is itself noisiest, so the true
errors are likely somewhat better than measured. Raising the gradient
fallback's coherence floor was tested (0.5/0.6/0.7): it trims harm ~2-4 points
but drops a fifth of statements and leaves the weak regions weak, so it was
NOT adopted. The client copy hedges direction as "roughly" and notes it is
least reliable around storm outflows.

Selection caveat: v1.2's constants were picked on the same five region-years
they are evaluated on. The grid is coarse (12 cells) and the winner won nearly
everywhere, so gross overfitting is unlikely, but a held-out year is the next
rigor step if these numbers ever need defending.

## Limits of this backtest

One region (Ohio Valley), one year, one center station. Ground truth is
pressure troughs, not analyzed fronts. The direction truth is itself a noisy
fit. The replay computes the center's own delta with the same `_delta3h`
helper rather than the production tendency resolver, and no interpreter/
forecast runs here, so only the observational statuses were tested. Duty and
FAR would differ somewhat in drier climates (fewer mesoscale troughs).
