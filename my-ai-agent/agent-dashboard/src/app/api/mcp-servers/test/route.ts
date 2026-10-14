import { NextResponse } from 'next/server'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import redis from '@/lib/redis'
import { MCP_SLUG_PATTERN } from '@/lib/mcp'
import type { McpTestResult } from '@/lib/types'

export const dynamic = 'force-dynamic'

const TEST_TIMEOUT_MS = 15_000

// Connects the same way the agent backend does (tools.py get_mcp_tool_schemas):
// {mcp_gateway_url}/{slug}/mcp with the x-portkey-api-key header, then one listTools().
// The URL and key always come from saved config, never from the browser, so the
// gateway key can't be sent to an arbitrary host.
export async function POST(req: Request) {
  const { slug } = (await req.json().catch(() => ({}))) as { slug?: unknown }
  if (typeof slug !== 'string' || !MCP_SLUG_PATTERN.test(slug)) {
    return NextResponse.json({ error: 'Invalid slug.' }, { status: 400 })
  }

  const [savedUrl, savedKey] = await redis.mget('config:mcp_gateway_url', 'config:gateway_api_key')
  const base = (savedUrl || process.env.PORTKEY_MCP_GATEWAY_URL || '').replace(/\/+$/, '')
  const apiKey = savedKey || process.env.PORTKEY_API_KEY || ''
  if (!base) {
    return NextResponse.json<McpTestResult>({ ok: false, error: 'No MCP Gateway URL is saved.' })
  }

  const started = Date.now()
  const client = new Client({ name: 'agent-dashboard', version: '1.0.0' })
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    const transport = new StreamableHTTPClientTransport(new URL(`${base}/${slug}/mcp`), {
      requestInit: { headers: { 'x-portkey-api-key': apiKey } },
    })
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`No response within ${TEST_TIMEOUT_MS / 1000} s`)), TEST_TIMEOUT_MS)
    })
    const { tools } = await Promise.race([
      client.connect(transport).then(() => client.listTools()),
      timeout,
    ])
    return NextResponse.json<McpTestResult>({
      ok: true,
      latency_ms: Date.now() - started,
      tools: tools.map((t) => ({ name: t.name, description: t.description ?? '' })),
    })
  } catch (e) {
    return NextResponse.json<McpTestResult>({ ok: false, error: e instanceof Error ? e.message : String(e) })
  } finally {
    clearTimeout(timer)
    await client.close().catch(() => {})
  }
}
