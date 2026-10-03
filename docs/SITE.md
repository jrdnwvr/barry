# barry.turpentine.cc

Written 2026-10-03 at Jordan's ask: a content plan for a very short site,
a few key features and no more. A how-to site with every feature spelled
out and directions for use comes later and is not this. This page is the
front door: what Barry is, three things it does, where to get it, how to
reach us. Privacy and support hang off it because the App Store listing
needs their URLs.

## Pages

- `/` the one page below.
- `/privacy` the policy, word for word from the backend's `/privacy`.
- `/support` the address and what to put in a note, from the backend's
  `/support`. A short FAQ can grow here later.

## The page, top to bottom

**1. Name and one line.** The icon, "Barry", and one line under it. Two
candidates:

- "Pressure, radar and wind for pilots. All of it from NOAA."
- "What the barometer is saying, and the radar to go with it."

Under that, the App Store badge once there is one. Until then: "Barry is
in TestFlight with a small group of pilots. Write for an invite." and the
address.

**2. One screenshot.** The dashboard with the verdict and the curve, on a
phone, nothing around it.

**3. Three features.** Each a short heading, two sentences, one
screenshot beside it. Proposed copy, Jordan's to rewrite:

- *See it coming.* "See when the weather will reach you and how strong
  it will be. The barometer is the oldest and most trusted instrument in
  forecasting because it works: a falling glass means something is
  coming, and how fast it falls says how much. Barry reads the last
  three hours at the station nearest you and puts it in a sentence, so
  you can make the call on what is actually happening where you are."
  (Jordan's ask: the benefit, not the feature.)
- *Radar with the weather around it.* "Six hours of radar that slides
  along its own motion instead of flickering frame to frame. Wind,
  stations, pressure lines and lightning move with the clock, so you can
  see what a front did on its way to you."
- *Aloft.* "Clouds, winds and temperatures by altitude for the next day,
  with turbulence and icing from NOAA's own products, drawn on a scale
  that gives the bottom six thousand feet the room they deserve."

A fourth if it earns its place: *The runway.* "The reported wind on each
runway end, and the density altitude now and this afternoon."

**4. Where the data comes from.** One paragraph: "Every number is NOAA's:
the Aviation Weather Center, the HRRR and NBM models, MRMS radar, the
GOES lightning mappers and the Weather Prediction Center. Barry's own
server reads them so your phone does not have to." Then the one calm
line the listing also carries: "Barry is for situational awareness. Get
a briefing before you fly."

**5. Footer.** barry@turpentine.cc, Privacy, Support, Turpentine.

That is the whole page. No feature grid, no icons in circles, no
testimonials, no newsletter.

## Voice

As the app and the TestFlight notes: short, plain, nothing that reads as
made by a machine. No "seamless", "powerful", "effortless" or "unlock".
White space over labels. One typeface, the app's own colours, the dark
scheme following the system. No em dashes.

## Screenshots

Four, taken from the iPhone 17 Pro simulator on a day with weather on
the radar, no device frames, no captions. The same set serves the App
Store listing at 6.9 inches:

1. The dashboard: verdict, curve, conditions card.
2. The radar mid-loop at the Ohio, Kentucky, Indiana zoom with Wind and
   Stations on.
3. The Aloft column with a cloud layer and some wind in it.
4. The watch face with the complication (watch simulator).

## Build and hosting

Built 2026-10-03, at Jordan's ask, in Payload (as tando-cms: Payload
3.86 on Next 16 with SQLite, under `site/` in this repo) so the words
and the screenshots are edited at `/admin` and the how-to site can grow
on the same CMS. The one page is the `site` global, privacy and support
are the `pages` collection, screenshots are `media`. An empty site
seeds itself on start (`src/seed.ts`): the first user from
`ADMIN_EMAIL` and `ADMIN_PASSWORD`, the words from this file, the
screenshots from `seed-assets/`. After that the admin owns the words.

Hosted on Tower for now, beside Tando: `site/docker-compose.yml`
(container `barry-site`, host port 3211; Tando is 3210), state in
`site/data` and `site/media`, joined to the backend's network so the
Barry tunnel reaches it as `http://barry-site:3000`. The public
hostname is Jordan's to add in the Cloudflare dashboard on the Barry
tunnel; `barry.turpentine.cc` later, or a wide-stack.com name first.
Deploy: `cd /mnt/user/appdata/barry && git pull && cd site && docker
compose up -d --build`. Locally `npm run dev` serves on 3001 (Tando
keeps 3000).

Once it is live, the backend's `/privacy` and `/support` redirect there
and the App Store listing's URLs point at it. The API stays on its own
name (`api.turpentine.cc` per `LAUNCH.md`), so the site and the server
move independently.

## Later, not now

The how-to site: every feature with directions for use, grown from
`FEATURES.md`, at `barry.turpentine.cc/guide` or its own subdomain.

## Decisions for Jordan

- The one line under the name.
- Three features or four.
- Whether the TestFlight invite line is public before the App Store.
