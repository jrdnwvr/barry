import { RichText } from '@payloadcms/richtext-lexical/react'
import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getPayload } from 'payload'
import React from 'react'

import config from '@/payload.config'

export const dynamic = 'force-dynamic'

type Args = { params: Promise<{ slug: string }> }

async function pageFor(slug: string) {
  const payload = await getPayload({ config: await config })
  const found = await payload.find({ collection: 'pages', where: { slug: { equals: slug } }, limit: 1 })
  return found.docs[0] ?? null
}

export async function generateMetadata({ params }: Args): Promise<Metadata> {
  const { slug } = await params
  const page = await pageFor(slug)
  return { title: page ? `${page.title} · Barry` : 'Barry' }
}

export default async function Page({ params }: Args) {
  const { slug } = await params
  const page = await pageFor(slug)
  if (!page) notFound()
  const dated = page.dated
    ? new Date(page.dated).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })
    : null

  return (
    <main className="page">
      <p className="crumb">
        <Link href="/">Barry</Link>
      </p>
      <h1>{page.title}</h1>
      {dated && <p className="meta">Last updated {dated}</p>}
      <RichText data={page.content} />
    </main>
  )
}
