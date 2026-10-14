import { NextResponse } from 'next/server'
import redis from '@/lib/redis'
import { validateMcpConfig } from '@/lib/mcp'
import type { McpServer, McpServersConfig } from '@/lib/types'

export const dynamic = 'force-dynamic'

function fromCommaList(raw: string | null | undefined): McpServer[] {
  return (raw ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((slug) => ({ slug, enabled: true }))
}

function parseSaved(raw: string | null): McpServer[] | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : null
  } catch {
    return null
  }
}

// Mirrors the backend's fallback order in get_live_config() so the page shows
// the servers the agent is actually using.
export async function GET() {
  const [savedRaw, legacyRaw, gatewayUrl] = await redis.mget(
    'config:mcp_servers',
    'config:mcp_server_slugs',
    'config:mcp_gateway_url',
  )

  let servers: McpServer[]
  let source: McpServersConfig['source']
  const saved = parseSaved(savedRaw)
  const legacy = fromCommaList(legacyRaw)
  const env = fromCommaList(process.env.PORTKEY_MCP_SERVER_SLUGS)
  if (saved) {
    servers = saved
    source = 'saved'
  } else if (legacy.length) {
    servers = legacy
    source = 'legacy'
  } else if (env.length) {
    servers = env
    source = 'env'
  } else {
    servers = []
    source = 'none'
  }

  const body: McpServersConfig = {
    mcp_gateway_url: gatewayUrl || process.env.PORTKEY_MCP_GATEWAY_URL || '',
    servers,
    source,
  }
  return NextResponse.json(body)
}

export async function PUT(req: Request) {
  const result = validateMcpConfig(await req.json().catch(() => null))
  if ('error' in result) return NextResponse.json({ error: result.error }, { status: 400 })

  await redis
    .pipeline()
    .set('config:mcp_servers', JSON.stringify(result.servers))
    .set('config:mcp_gateway_url', result.mcp_gateway_url)
    .del('config:mcp_server_slugs')
    .exec()
  return NextResponse.json({ ok: true })
}
