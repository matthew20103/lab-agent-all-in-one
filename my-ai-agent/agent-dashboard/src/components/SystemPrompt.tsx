'use client'

import { useState } from 'react'
import useSWR from 'swr'
import { Save, CheckCircle } from 'lucide-react'
import type { RedisConfig } from '@/lib/types'

const fetcher = (url: string) => fetch(url).then((r) => r.json())

export function SystemPrompt() {
  const { data: config, mutate } = useSWR<RedisConfig>('/api/config', fetcher)
  const [value, setValue] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  const current = value ?? config?.system_prompt ?? ''

  const handleSave = async () => {
    await fetch('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ system_prompt: current }),
    })
    mutate({ ...config!, system_prompt: current }, false)
    setSaved(true)
    setTimeout(() => setSaved(false), 2000)
  }

  return (
    <div className="max-w-3xl space-y-4">
      <div>
        <h2 className="text-lg font-semibold">System Instructions</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Changes take effect on the next message — no restart required.
        </p>
      </div>
      <textarea
        value={current}
        onChange={(e) => setValue(e.target.value)}
        rows={14}
        className="w-full bg-background border border-input rounded-lg px-4 py-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ring resize-none"
        placeholder="You are a helpful AI assistant."
      />
      <button
        onClick={handleSave}
        className="flex items-center gap-2 bg-primary text-primary-foreground px-4 py-2 rounded-md text-sm font-medium hover:bg-primary/90 transition-colors"
      >
        {saved ? (
          <>
            <CheckCircle className="w-4 h-4" />
            Saved
          </>
        ) : (
          <>
            <Save className="w-4 h-4" />
            Save &amp; Hot-Reload
          </>
        )}
      </button>
    </div>
  )
}
