import type { Metadata } from 'next'
import React from 'react'

import { Toggles } from '@/components/Toggles'
import './styles.css'

export const metadata: Metadata = {
  title: 'Barry',
  description: 'Pressure, radar and wind for pilots. All of it from NOAA.',
}

// The remembered switches go on <html> before the first paint, so a dark
// page does not open light and the iPad shots do not flash the phone's.
const remember = `(function(){try{var d=localStorage.getItem('device');if(d==='ipad')document.documentElement.dataset.device='ipad';var t=localStorage.getItem('theme');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t;}catch(e){}})();`

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: remember }} />
      </head>
      <body>
        <Toggles />
        {children}
      </body>
    </html>
  )
}
