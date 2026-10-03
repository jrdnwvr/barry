import { MigrateUpArgs, MigrateDownArgs, sql } from '@payloadcms/db-sqlite'

export async function up({ db, payload, req }: MigrateUpArgs): Promise<void> {
  await db.run(sql`ALTER TABLE \`site_features\` ADD \`image_ipad_id\` integer REFERENCES media(id);`)
  await db.run(sql`CREATE INDEX \`site_features_image_ipad_idx\` ON \`site_features\` (\`image_ipad_id\`);`)
  await db.run(sql`ALTER TABLE \`site\` ADD \`hero_ipad_id\` integer REFERENCES media(id);`)
  await db.run(sql`CREATE INDEX \`site_hero_ipad_idx\` ON \`site\` (\`hero_ipad_id\`);`)
}

export async function down({ db, payload, req }: MigrateDownArgs): Promise<void> {
  await db.run(sql`PRAGMA foreign_keys=OFF;`)
  await db.run(sql`CREATE TABLE \`__new_site_features\` (
  	\`_order\` integer NOT NULL,
  	\`_parent_id\` integer NOT NULL,
  	\`id\` text PRIMARY KEY NOT NULL,
  	\`title\` text NOT NULL,
  	\`body\` text NOT NULL,
  	\`image_id\` integer,
  	FOREIGN KEY (\`image_id\`) REFERENCES \`media\`(\`id\`) ON UPDATE no action ON DELETE set null,
  	FOREIGN KEY (\`_parent_id\`) REFERENCES \`site\`(\`id\`) ON UPDATE no action ON DELETE cascade
  );
  `)
  await db.run(sql`INSERT INTO \`__new_site_features\`("_order", "_parent_id", "id", "title", "body", "image_id") SELECT "_order", "_parent_id", "id", "title", "body", "image_id" FROM \`site_features\`;`)
  await db.run(sql`DROP TABLE \`site_features\`;`)
  await db.run(sql`ALTER TABLE \`__new_site_features\` RENAME TO \`site_features\`;`)
  await db.run(sql`PRAGMA foreign_keys=ON;`)
  await db.run(sql`CREATE INDEX \`site_features_order_idx\` ON \`site_features\` (\`_order\`);`)
  await db.run(sql`CREATE INDEX \`site_features_parent_id_idx\` ON \`site_features\` (\`_parent_id\`);`)
  await db.run(sql`CREATE INDEX \`site_features_image_idx\` ON \`site_features\` (\`image_id\`);`)
  await db.run(sql`CREATE TABLE \`__new_site\` (
  	\`id\` integer PRIMARY KEY NOT NULL,
  	\`tagline\` text NOT NULL,
  	\`hero_id\` integer,
  	\`store_u_r_l\` text,
  	\`testflight_line\` text,
  	\`data_paragraph\` text,
  	\`briefing_line\` text,
  	\`support_email\` text NOT NULL,
  	\`maker\` text,
  	\`updated_at\` text,
  	\`created_at\` text,
  	FOREIGN KEY (\`hero_id\`) REFERENCES \`media\`(\`id\`) ON UPDATE no action ON DELETE set null
  );
  `)
  await db.run(sql`INSERT INTO \`__new_site\`("id", "tagline", "hero_id", "store_u_r_l", "testflight_line", "data_paragraph", "briefing_line", "support_email", "maker", "updated_at", "created_at") SELECT "id", "tagline", "hero_id", "store_u_r_l", "testflight_line", "data_paragraph", "briefing_line", "support_email", "maker", "updated_at", "created_at" FROM \`site\`;`)
  await db.run(sql`DROP TABLE \`site\`;`)
  await db.run(sql`ALTER TABLE \`__new_site\` RENAME TO \`site\`;`)
  await db.run(sql`CREATE INDEX \`site_hero_idx\` ON \`site\` (\`hero_id\`);`)
}
