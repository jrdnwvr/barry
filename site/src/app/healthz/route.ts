export const dynamic = 'force-dynamic'

// Liveness for the host and an outside monitor. Does not touch the database.
export function GET(): Response {
  return new Response('ok', { status: 200, headers: { 'Cache-Control': 'no-store' } })
}
