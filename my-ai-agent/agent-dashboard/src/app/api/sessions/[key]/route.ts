import { NextResponse } from 'next/server'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

export async function GET(_: Request, { params }: { params: { key: string } }) {
  const raw = await redis.get(decodeURIComponent(params.key))
  if (!raw) return NextResponse.json([], { status: 404 })
  try {
    return NextResponse.json(JSON.parse(raw))
  } catch {
    return NextResponse.json([], { status: 500 })
  }
}
