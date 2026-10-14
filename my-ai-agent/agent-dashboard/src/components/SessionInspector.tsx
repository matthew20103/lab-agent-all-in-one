'use client'

import { useState } from 'react'
import useSWR from 'swr'
import { Download, RefreshCw, ChevronDown } from 'lucide-react'
import dynamic from 'next/dynamic'
import type { SessionMeta, ChatMessage } from '@/lib/types'

const ReactMarkdown = dynamic(() => import('react-markdown'), { ssr: false })

const fetcher = (url: string) => fetch(url).then((r) => r.json())

type ContentBlock = { type: string; text?: string; image_url?: { url?: string } }

function extractText(content: string | ContentBlock[] | unknown): string {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .map((block) => {
        if (typeof block === 'string') return block
        if (block?.type === 'text' && block?.text) return block.text
        if (block?.type === 'image_url') return '[image]'
        if (block?.type === 'image') return '[image]'
        return ''
      })
      .filter(Boolean)
      .join('\n') || '[no text content]'
  }
  return String(content ?? '')
}

function formatSession(key: string, ttl: number): string {
  const lastActive = new Date(Date.now() - (3600 - Math.max(ttl, 0)) * 1000)
  const mm = String(lastActive.getMonth() + 1).padStart(2, '0')
  const dd = String(lastActive.getDate()).padStart(2, '0')
  const hh = String(lastActive.getHours()).padStart(2, '0')
  const min = String(lastActive.getMinutes()).padStart(2, '0')
  const ss = String(lastActive.getSeconds()).padStart(2, '0')
  const id = key.split(':').pop()?.slice(0, 8) ?? key
  return `[${mm}-${dd} ${hh}:${min}:${ss}] (ID: ${id})`
}

export function SessionInspector() {
  const { data: sessions, mutate } = useSWR<SessionMeta[]>('/api/sessions', fetcher, {
    refreshInterval: 10000,
  })
  const [selectedKey, setSelectedKey] = useState<string>('')
  const { data: messages } = useSWR<ChatMessage[]>(
    selectedKey ? `/api/sessions/${encodeURIComponent(selectedKey)}` : null,
    fetcher,
    { refreshInterval: 5000 },
  )

  const handleExport = () => {
    window.location.href = '/api/sessions/export'
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold">Live Session Inspector</h2>
          <p className="text-sm text-muted-foreground mt-1">
            {sessions?.length ?? 0} active session(s) — sorted by most recent activity
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => mutate()}
            className="flex items-center gap-2 text-sm border border-border rounded-md px-3 py-1.5 hover:bg-accent transition-colors"
          >
            <RefreshCw className="w-3.5 h-3.5" />
            Refresh
          </button>
          <button
            onClick={handleExport}
            className="flex items-center gap-2 text-sm bg-primary text-primary-foreground rounded-md px-3 py-1.5 hover:bg-primary/90 transition-colors"
          >
            <Download className="w-3.5 h-3.5" />
            Export CSV
          </button>
        </div>
      </div>

      {!sessions?.length ? (
        <div className="text-muted-foreground text-sm py-8 text-center border border-dashed border-border rounded-lg">
          No active sessions found.
        </div>
      ) : (
        <div className="relative">
          <select
            value={selectedKey}
            onChange={(e) => setSelectedKey(e.target.value)}
            className="w-full appearance-none bg-background border border-input rounded-md px-3 py-2 text-sm pr-8 focus:outline-none focus:ring-2 focus:ring-ring"
          >
            <option value="">Select a session...</option>
            {sessions.map((s) => (
              <option key={s.key} value={s.key}>
                {formatSession(s.key, s.ttl)}
              </option>
            ))}
          </select>
          <ChevronDown className="absolute right-2 top-2.5 w-4 h-4 text-muted-foreground pointer-events-none" />
        </div>
      )}

      {selectedKey && messages && (
        <div className="border border-border rounded-lg overflow-hidden">
          <div className="bg-muted px-4 py-2 text-xs font-medium text-muted-foreground">
            {messages.length} message(s)
          </div>
          <div className="divide-y divide-border max-h-[60vh] overflow-y-auto">
            {messages.map((msg, i) => {
              if (msg.role === 'system') return null
              return (
                <div key={i} className="p-4">
                  {msg.role === 'user' && (
                    <div className="flex gap-2">
                      <span className="text-xs font-medium text-blue-500 mt-0.5 shrink-0">USER</span>
                      <p className="text-sm whitespace-pre-wrap">{extractText(msg.content)}</p>
                    </div>
                  )}
                  {msg.role === 'assistant' && (
                    <div className="flex gap-2">
                      <span className="text-xs font-medium text-green-500 mt-0.5 shrink-0">AGENT</span>
                      {msg.tool_calls?.length ? (
                        <p className="text-sm text-muted-foreground italic">
                          Used tool: {msg.tool_calls[0]?.function?.name}
                        </p>
                      ) : (
                        <div className="prose prose-sm dark:prose-invert max-w-none">
                          <ReactMarkdown>{extractText(msg.content)}</ReactMarkdown>
                        </div>
                      )}
                    </div>
                  )}
                  {msg.role === 'tool' && (
                    <details className="text-xs">
                      <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
                        View tool result
                      </summary>
                      <pre className="mt-2 bg-muted rounded p-2 overflow-x-auto whitespace-pre-wrap text-xs">
                        {extractText(msg.content)}
                      </pre>
                    </details>
                  )}
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
