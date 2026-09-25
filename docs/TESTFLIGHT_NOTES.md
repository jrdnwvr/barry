# TestFlight "What to Test"

Short. Plain. Sounds like a text from Jordan, not a release announcement.
Opening line every time, then three or four bullets at most, no bullet longer
than one line. No em dashes, no exclamation marks, no feature names in
quotes, no "we're excited". If a change needs a paragraph, it goes in a
conversation with the tester instead.

---

Thanks for testing. Send me anything that looks off, numbers that don't match the AWOS or ForeFlight, or anything that made you stop and think. A screenshot and a sentence is plenty.

This build:
- ...

---

## Log

- Build 82 (2026-09-17): first use of the long template (retired).
- Build 83 (2026-09-17, 9c5a4c6): cancelled before archive; more work queued first.
- Build 84 (2026-09-17, 78ef98f): storm row, watch sync + 6 h chart, shorter copy, I67 fix. First build on the short template.
- Build 85 (2026-09-19, 36a2561): internal only, new Internal only workflow (Turpentine group). Widgets, radar layers stack, home screen editor, Backcountry, Live Activity, TAF card.
- Build 86 (2026-09-20, 8cd51b4): Pilots. Same content as 85. Notes written by Jordan.
- Build 87 (2026-09-25, 17849f7): failed, CompileMetalFile; the Xcode 27 cloud image cannot run the Metal compiler.
- Build 88 (2026-09-25, e2a0ac0): failed in a post-clone script that tried to download the toolchain ("already imported").
- Build 89 (2026-09-25, 8c4cdc4): the shader compiled on the device instead; archive succeeded, cancelled before TestFlight so the wind speed labels could go in.
- Build 90 (2026-09-25, 4108fe0): cancelled before TestFlight; the labelled arrows were far too dense at the levels.
- Build 91 (2026-09-25): Pilots. NOAA switch: radar from MRMS with nowcast and lightning chance, rain line, Aloft turbulence and icing, LAMP TAF stand-in, saved map presets, height contours, the rate-limited tile fix, speed labels on the wind arrows thinned to a readable lattice. Notes written by Jordan.
