import { getPayload } from 'payload'
import Link from 'next/link'
import React from 'react'

import config from '@/payload.config'
import type { Media } from '@/payload-types'

export const dynamic = 'force-dynamic'

const Shot = ({ image, className }: { image?: Media | number | null; className?: string }) => {
  if (!image || typeof image === 'number' || !image.url) return null
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      className={className}
      src={image.url}
      alt={image.alt}
      width={image.width ?? undefined}
      height={image.height ?? undefined}
      loading="lazy"
    />
  )
}

/** The phone's and the iPad's screenshot; the switch at the top shows one. */
const Shots = ({ phone, pad, className }: { phone?: Media | number | null; pad?: Media | number | null; className: string }) => (
  <>
    <Shot image={phone} className={`${className} phone`} />
    <Shot image={pad ?? phone} className={`${className} pad`} />
  </>
)

export default async function Home() {
  const payload = await getPayload({ config: await config })
  const site = await payload.findGlobal({ slug: 'site' })
  const features = site.features ?? []

  return (
    <main>
      <header className="top">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img className="icon" src="/icon.png" alt="" width={72} height={72} />
        <h1>Barry</h1>
        <p className="tagline">{site.tagline}</p>
        {site.storeURL ? (
          <a className="store" href={site.storeURL}>
            Download on the App Store
          </a>
        ) : site.testflightLine ? (
          <p className="invite">
            {site.testflightLine}{' '}
            <a href={`mailto:${site.supportEmail}`}>{site.supportEmail}</a>
          </p>
        ) : null}
      </header>

      <Shots phone={site.hero} pad={site.heroIpad} className="hero" />

      {features.map((f, i) => (
        <section className={`feature ${i % 2 ? 'flip' : ''}`} key={f.id ?? i}>
          <div className="words">
            <h2>{f.title}</h2>
            <p>{f.body}</p>
          </div>
          <Shots phone={f.image} pad={f.imageIpad} className="shot" />
        </section>
      ))}

      {(site.dataParagraph || site.briefingLine) && (
        <section className="data">
          {site.dataParagraph && <p>{site.dataParagraph}</p>}
          {site.briefingLine && <p className="brief">{site.briefingLine}</p>}
        </section>
      )}

      <footer>
        <a href={`mailto:${site.supportEmail}`}>{site.supportEmail}</a>
        <Link href="/privacy">Privacy</Link>
        <Link href="/support">Support</Link>
        {site.maker && <span>{site.maker}</span>}
      </footer>
    </main>
  )
}
