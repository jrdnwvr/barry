//  The site's first content, written on start when there is none: the first
//  user from ADMIN_EMAIL and ADMIN_PASSWORD, the screenshots in seed-assets,
//  the one page's words from docs/SITE.md, and the privacy and support
//  pages from the server's old /privacy and /support. After that the admin
//  owns the words; this never overwrites.

import fs from 'fs'
import path from 'path'
import type { Payload } from 'payload'

// ---- a little markdown into Lexical, enough for these two pages ----------

const text = (t: string) => ({ type: 'text', text: t, detail: 0, format: 0, mode: 'normal', style: '', version: 1 })
const block = (type: string, children: unknown[], extra: Record<string, unknown> = {}) => ({
  type,
  children,
  direction: 'ltr',
  format: '',
  indent: 0,
  version: 1,
  ...extra,
})

/** Inline: plain text with [label](url) links. */
const inline = (s: string) => {
  const out: unknown[] = []
  const re = /\[([^\]]+)\]\(([^)]+)\)/g
  let last = 0
  for (const m of s.matchAll(re)) {
    if (m.index! > last) out.push(text(s.slice(last, m.index)))
    out.push(block('link', [text(m[1])], { fields: { linkType: 'custom', url: m[2], newTab: false } }))
    last = m.index! + m[0].length
  }
  if (last < s.length) out.push(text(s.slice(last)))
  return out
}

/** Blocks: "## " headings, "- " bullets, blank-line paragraphs. */
export const lexical = (md: string) => {
  const children: unknown[] = []
  let bullets: unknown[] = []
  const flush = () => {
    if (bullets.length) {
      children.push(block('list', bullets, { listType: 'bullet', start: 1, tag: 'ul' }))
      bullets = []
    }
  }
  for (const raw of md.trim().split(/\n{2,}/)) {
    const para = raw.trim()
    if (para.startsWith('## ')) {
      flush()
      children.push(block('heading', [text(para.slice(3))], { tag: 'h2' }))
    } else if (para.startsWith('- ')) {
      for (const [i, line] of para.split('\n').entries()) {
        bullets.push(block('listitem', inline(line.replace(/^- /, '')), { value: i + 1 }))
      }
    } else {
      flush()
      children.push(block('paragraph', inline(para.replace(/\n/g, ' ')), { textFormat: 0, textStyle: '' }))
    }
  }
  flush()
  return { root: { type: 'root', children, direction: 'ltr', format: '', indent: 0, version: 1 } }
}

// ---- the words -----------------------------------------------------------

const EMAIL = 'barry@turpentine.cc'

const privacy = `
Barry is a barometric pressure app for pilots and weather watchers. It is built by one person, has no accounts, no advertising, and no analytics. This page explains the little data it does handle.

## Location

If you allow it, Barry uses your device's location to find the nearest weather-reporting station and to center the radar. Your coordinates are sent to Barry's own server as part of the request for that station's data, and the server uses them to build the response. They are not stored beyond a short in-memory cache used to answer repeat requests, and they are not shared with anyone. You can use Barry without location by picking a station yourself.

## Barometer

On phones with a barometer, Barry can read the sensor to compare against the nearest station. Those readings stay on your device.

## Weather data sources

Barry's server fetches public weather data on your behalf so your device never contacts these services directly:

- NOAA Aviation Weather Center (METAR and TAF reports, advisories, pilot reports)
- NOAA Open Data and NOAA NOMADS (forecast models, turbulence and icing analyses, station guidance, GOES lightning)
- NOAA National Data Buoy Center (buoys and coastal stations)
- Iowa Environmental Mesonet (NWS surface analysis bulletins)
- OurAirports (runway data, bundled with the server)

Radar map tiles are served by Barry's own server, and the base map comes from Apple Maps, which receives the standard technical information any web request carries, such as your IP address. Apple's own privacy policy covers Maps.

## Notifications

Storm alerts are local notifications scheduled on your device from the forecast data. No push tokens or notification data leave your device.

## What Barry does not do

Barry does not collect your name, email, contacts, or any identifier; does not use third-party analytics or advertising SDKs; and does not sell or share data.

## Diagnostics

iOS collects app performance and crash reports on the device (Apple's MetricKit) and hands them to the app about once a day. Barry sends those reports to its own server so problems can be fixed. They contain timing, battery and crash information about the app itself, and no location, name or identifier. They are kept as files on the server for a few weeks and read only when something needs looking into.

## Server logs

Barry's server does not keep a per-request log. It records errors and warnings, which do not include your coordinates or address, for a short period to diagnose problems. They are not used for anything else.

## Changes and contact

If this policy changes, the date above will be updated. Questions: [${EMAIL}](mailto:${EMAIL}).
`

const support = `
Barry watches barometric pressure and tells you, in plain language, what the trend means for the next day of flying or weather. It is made by one pilot and works best with your questions and corrections.

## Get in touch

Write to [${EMAIL}](mailto:${EMAIL}). Say which station you were looking at and roughly when, and a screenshot helps. The Write to Barry row in the app's Settings starts a note with the version, your station and the phone already in it.

## Where the data comes from

Station reports are METARs and TAFs from the NOAA Aviation Weather Center. Forecasts, winds aloft, turbulence and icing come from NOAA's own models (HRRR, NBM, LAMP, GTG, CIP), run on Barry's server; outside their coverage there is none. Radar is NOAA's MRMS, drawn on Barry's server. Lightning is from the GOES satellites. Fronts are the Weather Prediction Center's surface analysis. Runway headings are from OurAirports.

## A note on the front watch

The front watch reads pressure changes at stations around you. In testing across five climates it was right about six times in ten, so treat it as a heads-up, not a briefing.

## Privacy

The [privacy policy](/privacy) is short, and all of it is true.
`

// Each feature's screenshot on a phone and on an iPad (asset-ipad.png),
// for the switch at the top of the page.
const features = [
  {
    title: 'See it coming',
    body: 'See when the weather will reach you and how strong it will be. The barometer is the oldest and most trusted instrument in forecasting because it works: a falling glass means something is coming, and how fast it falls says how much. Barry reads the last three hours at the station nearest you and puts it in a sentence, so you can make the call on what is actually happening where you are.',
    asset: 'dashboard',
    alt: "Barry's dashboard: the pressure, the verdict in a sentence and the curve",
  },
  {
    title: 'Radar with the weather around it',
    body: 'Six hours of radar that slides along its own motion instead of flickering frame to frame. Wind, stations, pressure lines and lightning move with the clock, so you can see what a front did on its way to you.',
    asset: 'radar',
    alt: 'The radar loop with wind streaks and station reports on the map',
  },
  {
    title: 'Aloft',
    body: "Clouds, winds and temperatures by altitude for the next day, with turbulence and icing from NOAA's own products, drawn on a scale that gives the bottom six thousand feet the room they deserve.",
    asset: 'aloft',
    alt: 'The Aloft column: cloud layers, winds and temperatures by altitude',
  },
]

// ---- on start --------------------------------------------------------------

export const seedIfEmpty = async (payload: Payload) => {
  if (!process.env.DATABASE_URL) return
  try {
    const users = await payload.count({ collection: 'users' })
    if (users.totalDocs === 0) {
      const email = process.env.ADMIN_EMAIL
      const password = process.env.ADMIN_PASSWORD
      if (email && password) {
        await payload.create({ collection: 'users', data: { email, password } })
        payload.logger.info(`seed: first user ${email}`)
      } else {
        payload.logger.warn('seed: ADMIN_EMAIL and ADMIN_PASSWORD unset, no first user made')
      }
    }

    const site = await payload.findGlobal({ slug: 'site' })
    if (site.tagline) return

    const assets = path.resolve(process.cwd(), 'seed-assets')
    const upload = async (name: string, alt: string) => {
      const filePath = path.join(assets, name)
      if (!fs.existsSync(filePath)) return undefined
      const doc = await payload.create({ collection: 'media', data: { alt }, filePath })
      return doc.id
    }

    const shots: Record<string, number | undefined> = {}
    for (const f of features) {
      shots[f.asset] = await upload(`${f.asset}.png`, f.alt)
      shots[`${f.asset}-ipad`] = await upload(`${f.asset}-ipad.png`, `${f.alt}, on an iPad`)
    }

    for (const [slug, title, content] of [
      ['privacy', 'Privacy', privacy],
      ['support', 'Support', support],
    ] as const) {
      const have = await payload.count({ collection: 'pages', where: { slug: { equals: slug } } })
      if (have.totalDocs === 0) {
        await payload.create({
          collection: 'pages',
          data: { slug, title, dated: new Date().toISOString(), content: lexical(content) as never },
        })
      }
    }

    await payload.updateGlobal({
      slug: 'site',
      data: {
        tagline: 'Pressure, radar and wind for pilots. All of it from NOAA.',
        hero: shots['dashboard'],
        heroIpad: shots['dashboard-ipad'],
        testflightLine: 'Barry is in TestFlight with a small group of pilots. Write for an invite:',
        features: features.map((f) => ({
          title: f.title,
          body: f.body,
          image: shots[f.asset],
          imageIpad: shots[`${f.asset}-ipad`],
        })),
        dataParagraph:
          "Every number is NOAA's: the Aviation Weather Center, the HRRR and NBM models, MRMS radar, the GOES lightning mappers and the Weather Prediction Center. Barry's own server reads them so your phone does not have to.",
        briefingLine: 'Barry is for situational awareness. Get a briefing before you fly.',
        supportEmail: EMAIL,
        maker: 'Turpentine',
      },
    })
    payload.logger.info('seed: the site has its first words')
  } catch (err) {
    payload.logger.error({ err }, 'seed: failed')
  }
}
