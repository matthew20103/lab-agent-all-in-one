import { NextResponse } from 'next/server'
import redis from '@/lib/redis'
import { A2A_SLUG_PATTERN, defaultCardUrl } from '@/lib/a2a'
import type { A2aAgent, A2aTestResult } from '@/lib/types'

export const dynamic = 'force-dynamic'

const TEST_TIMEOUT_MS = 15_000

interface RawCard {
  name?: string
  description?: string
  protocolVersion?: string
  url?: string
  supportedInterfaces?: { url?: string; protocolVersion?: string }[]
  skills?: { name?: string; description?: string }[]
}

// Fetches the saved agent's card the same way the backend does (a2a_agents.py): from the
// card URL override if one is set (no gateway key — that host isn't the gateway), otherwise
// from {url}/.well-known/agent-card.json with the x-portkey-api-key header. URLs and key come
// from saved config, never from the browser, so the key only goes to saved gateway URLs.
export async function POST(req: Request) {
  const { slug } = (await req.json().catch(() => ({}))) as { slug?: unknown }
  if (typeof slug !== 'string' || !A2A_SLUG_PATTERN.test(slug)) {
    return NextResponse.json({ error: 'Invalid slug.' }, { status: 400 })
  }

  const [savedRaw, savedKey] = await redis.mget('config:a2a_agents', 'config:gateway_api_key')
  let agent: A2aAgent | undefined
  try {
    agent = (JSON.parse(savedRaw ?? '[]') as A2aAgent[]).find((a) => a.slug === slug)
  } catch {
    agent = undefined
  }
  if (!agent) {
    return NextResponse.json<A2aTestResult>({ ok: false, error: 'Save this agent first; tests use the saved URL.' })
  }

  const cardSource = agent.card_url ? 'card_url' : 'gateway'
  const started = Date.now()
  try {
    const resp = agent.card_url
      ? await fetch(agent.card_url, { signal: AbortSignal.timeout(TEST_TIMEOUT_MS), cache: 'no-store' })
      : await fetch(defaultCardUrl(agent.url), {
          headers: { 'x-portkey-api-key': savedKey || process.env.PORTKEY_API_KEY || '' },
          signal: AbortSignal.timeout(TEST_TIMEOUT_MS),
          cache: 'no-store',
        })
    if (!resp.ok) {
      const text = (await resp.text()).slice(0, 300)
      return NextResponse.json<A2aTestResult>({ ok: false, error: `HTTP ${resp.status}: ${text}` })
    }
    const card = (await resp.json()) as RawCard
    const interfaces = card.supportedInterfaces ?? []
    return NextResponse.json<A2aTestResult>({
      ok: true,
      latency_ms: Date.now() - started,
      card_source: cardSource,
      name: card.name ?? '(unnamed)',
      description: card.description ?? '',
      // v0.3 cards carry protocolVersion at the top level; v1.0 cards per interface
      protocol_version: card.protocolVersion ?? interfaces[0]?.protocolVersion ?? 'unknown',
      endpoints: [card.url, ...interfaces.map((i) => i.url)].filter((u): u is string => Boolean(u)),
      skills: (card.skills ?? []).map((s) => ({ name: s.name ?? '', description: s.description ?? '' })),
    })
  } catch (e) {
    return NextResponse.json<A2aTestResult>({ ok: false, error: e instanceof Error ? e.message : String(e) })
  }
}
