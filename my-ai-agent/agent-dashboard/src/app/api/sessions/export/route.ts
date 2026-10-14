import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

export async function GET() {
  const keys = await redis.keys('session:*')
  const rows = ['Session ID,Role,Content']

  for (const key of keys) {
    const raw = await redis.get(key)
    if (!raw) continue
    try {
      const msgs: Array<{ role: string; content: string }> = JSON.parse(raw)
      const sessionId = key.split(':').pop() ?? key
      for (const m of msgs) {
        const escaped = (m.content ?? '').replace(/"/g, '""')
        rows.push(`"${sessionId}","${m.role}","${escaped}"`)
      }
    } catch {
      // skip malformed
    }
  }

  return new Response(rows.join('\n'), {
    headers: {
      'Content-Type': 'text/csv',
      'Content-Disposition': 'attachment; filename="sessions.csv"',
    },
  })
}
