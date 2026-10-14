// Auth handled at Caddy reverse proxy layer
export async function GET() {
  return new Response('Not used', { status: 404 })
}
export async function POST() {
  return new Response('Not used', { status: 404 })
}
