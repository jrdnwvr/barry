# The same shape as tando-cms: Next's standalone output on node:22-alpine.
# next.config.ts sets `output: 'standalone'`.

FROM node:22.17.0-alpine AS base

FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
# .npmrc rides along: the lockfile is resolved with legacy-peer-deps=true.
COPY package.json package-lock.json .npmrc ./
RUN npm ci

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=builder /app/public ./public
RUN mkdir .next
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
# The screenshots the seed uploads on an empty site.
COPY --from=builder /app/seed-assets ./seed-assets

# /app/data (SQLite) and /app/media (uploads) are bind mounts from compose;
# the container runs as root so mount ownership never blocks writes on Unraid.
RUN mkdir -p data media

EXPOSE 3000
ENV PORT=3000

CMD ["sh", "-c", "mkdir -p \"${MEDIA_DIR:-/app/media}\" && HOSTNAME=0.0.0.0 exec node server.js"]
