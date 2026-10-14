import { NextResponse } from 'next/server'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

export async function GET() {
  const keys = await redis.keys('session:*')
  const withTtl = await Promise.all(
    keys.map(async (key) => ({ key, ttl: await redis.ttl(key) })),
  )
  withTtl.sort((a, b) => b.ttl - a.ttl)
  return NextResponse.json(withTtl)
}
