import { NextResponse } from 'next/server'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

export async function DELETE() {
  const keys = await redis.keys('session:*')
  if (keys.length) await redis.del(...keys)
  return NextResponse.json({ deleted: keys.length })
}
