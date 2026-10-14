import { NextResponse } from 'next/server'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

export async function GET() {
  const [prompt, connMethod, gatewayUrl, gatewayApiKey, visionCapable] = await redis.mget(
    'config:system_prompt',
    'config:connection_method',
    'config:gateway_url',
    'config:gateway_api_key',
    'config:vision_capable',
  )

  return NextResponse.json({
    system_prompt: prompt ?? 'You are a helpful AI assistant.',
    connection_method: connMethod ?? 'websocket',
    gateway_url: gatewayUrl || process.env.PORTKEY_GATEWAY_URL || '',
    gateway_api_key: gatewayApiKey ?? '',
    vision_capable: visionCapable === 'true',
  })
}

export async function POST(req: Request) {
  const body = await req.json()
  const pipeline = redis.pipeline()

  if (body.system_prompt !== undefined) pipeline.set('config:system_prompt', body.system_prompt)
  if (body.connection_method !== undefined) pipeline.set('config:connection_method', body.connection_method)
  if (body.gateway_url !== undefined) pipeline.set('config:gateway_url', body.gateway_url)
  if (body.gateway_api_key !== undefined) pipeline.set('config:gateway_api_key', body.gateway_api_key)
  if (body.vision_capable !== undefined) pipeline.set('config:vision_capable', body.vision_capable ? 'true' : 'false')

  await pipeline.exec()
  return NextResponse.json({ ok: true })
}
