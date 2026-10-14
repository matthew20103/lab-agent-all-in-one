import { NextResponse } from 'next/server'
import redis from '@/lib/redis'
import { validateA2aConfig } from '@/lib/a2a'
import type { A2aAgent, A2aAgentsConfig } from '@/lib/types'

export const dynamic = 'force-dynamic'

function parseSaved(raw: string | null): A2aAgent[] {
  if (!raw) return []
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

export async function GET() {
  const body: A2aAgentsConfig = { agents: parseSaved(await redis.get('config:a2a_agents')) }
  return NextResponse.json(body)
}

export async function PUT(req: Request) {
  const result = validateA2aConfig(await req.json().catch(() => null))
  if ('error' in result) return NextResponse.json({ error: result.error }, { status: 400 })
  await redis.set('config:a2a_agents', JSON.stringify(result.agents))
  return NextResponse.json({ ok: true })
}
