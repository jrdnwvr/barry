import type { GlobalConfig } from 'payload'

/** The one page, top to bottom, as docs/SITE.md lays it out. */
export const Site: GlobalConfig = {
  slug: 'site',
  access: {
    read: () => true,
  },
  fields: [
    {
      name: 'tagline',
      type: 'text',
      required: true,
      admin: { description: 'The one line under the name.' },
    },
    {
      name: 'hero',
      type: 'upload',
      relationTo: 'media',
      admin: { description: 'One screenshot, nothing around it.' },
    },
    {
      name: 'heroIpad',
      type: 'upload',
      relationTo: 'media',
      admin: { description: 'The same on an iPad, for the iPad switch.' },
    },
    {
      name: 'storeURL',
      type: 'text',
      admin: { description: 'The App Store link; the badge shows once this is set.' },
    },
    {
      name: 'testflightLine',
      type: 'text',
      admin: { description: 'Shown while there is no store link.' },
    },
    {
      name: 'features',
      type: 'array',
      maxRows: 4,
      fields: [
        { name: 'title', type: 'text', required: true },
        { name: 'body', type: 'textarea', required: true },
        { name: 'image', type: 'upload', relationTo: 'media', admin: { description: 'On an iPhone.' } },
        { name: 'imageIpad', type: 'upload', relationTo: 'media', admin: { description: 'On an iPad.' } },
      ],
    },
    {
      name: 'dataParagraph',
      type: 'textarea',
      admin: { description: 'Where the data comes from.' },
    },
    {
      name: 'briefingLine',
      type: 'text',
      admin: { description: 'The calm line: situational awareness, get a briefing.' },
    },
    { name: 'supportEmail', type: 'email', required: true },
    {
      name: 'maker',
      type: 'text',
      admin: { description: 'The name in the footer.' },
    },
  ],
}
