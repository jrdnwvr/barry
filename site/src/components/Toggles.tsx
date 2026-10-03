'use client'

//  Two switches: which screenshots the page shows (iPhone or iPad), at the
//  top, and light or dark, at the top right. Both are a data attribute on
//  <html> that the stylesheet reads, remembered in this browser; the
//  layout's inline script applies the remembered values before paint.

import { usePathname } from 'next/navigation'
import React, { useSyncExternalStore } from 'react'

type Device = 'iphone' | 'ipad'
type Theme = 'auto' | 'light' | 'dark'

// The remembered values as a store, so the first render on the server and
// the hydrating render agree (the defaults) and the browser's own values
// follow right after.
const listeners = new Set<() => void>()
const subscribe = (cb: () => void) => {
  listeners.add(cb)
  return () => {
    listeners.delete(cb)
  }
}
const read = (key: string) => {
  try {
    return window.localStorage.getItem(key)
  } catch {
    return null
  }
}
const write = (key: string, value: string) => {
  try {
    window.localStorage.setItem(key, value)
  } catch {}
  listeners.forEach((l) => l())
}
const useRemembered = <T extends string>(key: string, fallback: T, allowed: readonly T[]) =>
  useSyncExternalStore(
    subscribe,
    () => {
      const v = read(key)
      return (allowed as readonly string[]).includes(v ?? '') ? (v as T) : fallback
    },
    () => fallback,
  )

export function Toggles() {
  const pathname = usePathname()
  const device = useRemembered<Device>('device', 'iphone', ['iphone', 'ipad'])
  const theme = useRemembered<Theme>('theme', 'auto', ['auto', 'light', 'dark'])

  const pickDevice = (d: Device) => {
    document.documentElement.dataset.device = d
    write('device', d)
  }

  const pickTheme = () => {
    // Auto, then the opposite of what is showing, then back to auto.
    const dark = window.matchMedia('(prefers-color-scheme: dark)').matches
    const showing = theme === 'auto' ? (dark ? 'dark' : 'light') : theme
    const next: Theme = theme === 'auto' ? (showing === 'dark' ? 'light' : 'dark') : 'auto'
    if (next === 'auto') delete document.documentElement.dataset.theme
    else document.documentElement.dataset.theme = next
    write('theme', next)
  }

  return (
    <div className="toggles">
      {pathname === '/' && (
        <div className="device" role="group" aria-label="Screenshots">
          <button type="button" aria-pressed={device === 'iphone'} onClick={() => pickDevice('iphone')}>
            iPhone
          </button>
          <button type="button" aria-pressed={device === 'ipad'} onClick={() => pickDevice('ipad')}>
            iPad
          </button>
        </div>
      )}
      <button type="button" className="theme" onClick={pickTheme} aria-label="Light or dark" title="Light or dark">
        {theme === 'auto' ? 'Auto' : theme === 'dark' ? 'Dark' : 'Light'}
      </button>
    </div>
  )
}
