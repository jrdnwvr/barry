import type { CollectionConfig } from 'payload'

/** The pages hanging off the front door: privacy and support today. */
export const Pages: CollectionConfig = {
  slug: 'pages',
  admin: {
    useAsTitle: 'title',
    defaultColumns: ['title', 'slug', 'updatedAt'],
  },
  access: {
    read: () => true,
  },
  fields: [
    { name: 'title', type: 'text', required: true },
    {
      name: 'slug',
      type: 'text',
      required: true,
      unique: true,
      admin: { description: 'The path: privacy, support.' },
    },
    {
      name: 'dated',
      type: 'date',
      admin: { description: 'Shown as "Last updated" under the title when set.' },
    },
    { name: 'content', type: 'richText', required: true },
  ],
}
