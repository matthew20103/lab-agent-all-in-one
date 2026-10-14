'use client'

import { useState } from 'react'
import Link from 'next/link'
import useSWR from 'swr'
import { Trash2, Radio, Plug, Save, CheckCircle, Bot } from 'lucide-react'
import { BrandLogo } from './BrandLogo'
import { ThemeToggle } from './ThemeToggle'
import type { A2aAgentsConfig, McpServersConfig, RedisConfig } from '@/lib/types'

const fetcher = (url: string) => fetch(url).then((r) => r.json())

async function saveConfig(partial: Partial<RedisConfig>) {
  await fetch('/api/config', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(partial),
  })
}

const asideClass = 'flex h-full w-[300px] shrink-0 flex-col border-r border-border bg-sidebar p-5'
const sectionLabel = 'text-xs font-semibold text-muted-foreground uppercase tracking-wide block mb-2'
const inputClass =
  'w-full bg-background border border-input rounded-lg px-3 py-2 text-sm mb-2 focus:border-transparent focus:outline-none focus:ring-2 focus:ring-ring'

const CONNECTION_OPTIONS = [
  { value: 'websocket', label: 'WebSocket (WSS)' },
  { value: 'sse', label: 'Streaming HTTP (SSE)' },
  { value: 'rest', label: 'REST API (Blocking)' },
]

export function Sidebar() {
  const { data: config, mutate } = useSWR<RedisConfig>('/api/config', fetcher, {
    refreshInterval: 10000,
  })
  const { data: mcp } = useSWR<McpServersConfig>('/api/mcp-servers', fetcher, { refreshInterval: 10000 })
  const { data: a2a } = useSWR<A2aAgentsConfig>('/api/a2a-agents', fetcher, { refreshInterval: 10000 })
  // Typed fields keep a local draft and save on the button, so a half-typed URL never goes live.
  const [draftGatewayUrl, setDraftGatewayUrl] = useState<string | null>(null)
  const [draftGatewayKey, setDraftGatewayKey] = useState<string | null>(null)
  const [gatewaySaved, setGatewaySaved] = useState(false)

  if (!config) {
    return (
      <aside className={`${asideClass} items-center justify-center`}>
        <div className="text-muted-foreground text-sm">Loading...</div>
      </aside>
    )
  }

  const update = async (partial: Partial<RedisConfig>) => {
    await saveConfig(partial)
    mutate({ ...config, ...partial }, false)
  }

  const gatewayUrl = draftGatewayUrl ?? config.gateway_url
  const gatewayKey = draftGatewayKey ?? config.gateway_api_key
  const gatewayDirty = gatewayUrl !== config.gateway_url || gatewayKey !== config.gateway_api_key
  const enabledMcp = mcp?.servers.filter((s) => s.enabled).length
  const enabledA2a = a2a?.agents.filter((a) => a.enabled).length

  const handleSaveGateway = async () => {
    await update({ gateway_url: gatewayUrl.trim(), gateway_api_key: gatewayKey.trim() })
    setDraftGatewayUrl(null)
    setDraftGatewayKey(null)
    setGatewaySaved(true)
    setTimeout(() => setGatewaySaved(false), 2000)
  }

  const handleClearHistory = async () => {
    if (!confirm('Delete all active sessions?')) return
    await fetch('/api/history', { method: 'DELETE' })
  }

  return (
    <aside className={asideClass}>
      <header className="mb-6">
        <BrandLogo className="h-7" />
        <h1 className="mt-4 text-xl font-bold tracking-tight">Agent Dashboard</h1>
        <p className="mt-0.5 text-sm text-muted-foreground">AI Agent All in One</p>
      </header>

      <div className="flex-1 overflow-y-auto space-y-6 -mx-1 px-1">

        {/* AI Gateway */}
        <section>
          <label className={sectionLabel}>AI Gateway</label>
          <input
            type="text"
            value={gatewayUrl}
            onChange={(e) => setDraftGatewayUrl(e.target.value)}
            placeholder="Gateway URL (http://gateway-host:8787/v1)"
            className={`${inputClass} font-mono`}
          />
          <input
            type="password"
            value={gatewayKey}
            onChange={(e) => setDraftGatewayKey(e.target.value)}
            placeholder="Gateway API Key"
            className={inputClass}
          />
          <button
            onClick={handleSaveGateway}
            disabled={!gatewayDirty}
            className="w-full flex items-center justify-center gap-2 bg-primary text-primary-foreground rounded-lg px-3 py-2 text-sm font-medium mb-3 hover:bg-primary/90 transition-colors disabled:opacity-50 disabled:pointer-events-none"
          >
            {gatewaySaved ? <CheckCircle className="w-3.5 h-3.5" /> : <Save className="w-3.5 h-3.5" />}
            {gatewaySaved ? 'Saved' : 'Save gateway settings'}
          </button>
          <label className="flex items-center gap-2 cursor-pointer">
            <div
              role="switch"
              aria-checked={config.vision_capable}
              onClick={() => update({ vision_capable: !config.vision_capable })}
              className={`relative w-9 h-5 rounded-full transition-colors cursor-pointer ${
                config.vision_capable ? 'bg-primary' : 'bg-muted'
              }`}
            >
              <span
                className={`absolute top-0.5 left-0.5 w-4 h-4 rounded-full bg-white shadow transition-transform ${
                  config.vision_capable ? 'translate-x-4' : ''
                }`}
              />
            </div>
            <span className="text-sm">Vision-capable</span>
          </label>
        </section>

        {/* MCP servers — managed on their own tab */}
        <section>
          <label className={sectionLabel}>Tools &amp; Sub-agents</label>
          <Link
            href="/dashboard/mcp-servers"
            className="flex items-center justify-between gap-2 text-sm border border-border bg-background rounded-lg px-3 py-2 shadow-sm hover:border-primary/50 transition-colors"
          >
            <span className="flex items-center gap-2">
              <Plug className="w-3.5 h-3.5 text-muted-foreground" />
              {enabledMcp === undefined ? 'MCP servers' : `${enabledMcp} server${enabledMcp === 1 ? '' : 's'} enabled`}
            </span>
            <span className="text-xs text-muted-foreground">Manage →</span>
          </Link>
          <Link
            href="/dashboard/agents"
            className="mt-2 flex items-center justify-between gap-2 text-sm border border-border bg-background rounded-lg px-3 py-2 shadow-sm hover:border-primary/50 transition-colors"
          >
            <span className="flex items-center gap-2">
              <Bot className="w-3.5 h-3.5 text-muted-foreground" />
              {enabledA2a === undefined ? 'Sub-agents' : `${enabledA2a} sub-agent${enabledA2a === 1 ? '' : 's'} enabled`}
            </span>
            <span className="text-xs text-muted-foreground">Manage →</span>
          </Link>
        </section>

        {/* Connection Method */}
        <section>
          <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wide flex items-center gap-1.5 mb-2">
            <Radio className="w-3 h-3" />
            Connection Method
          </label>
          <div className="space-y-1">
            {CONNECTION_OPTIONS.map((opt) => (
              <label key={opt.value} className="flex items-center gap-2 cursor-pointer">
                <input
                  type="radio"
                  name="connection_method"
                  value={opt.value}
                  checked={config.connection_method === opt.value}
                  onChange={() => update({ connection_method: opt.value })}
                  className="accent-primary"
                />
                <span className="text-sm">{opt.label}</span>
              </label>
            ))}
          </div>
        </section>

      </div>

      <footer className="mt-4 flex items-center gap-2">
        <ThemeToggle />
        <button
          onClick={handleClearHistory}
          className="ml-auto flex items-center gap-1.5 text-sm text-destructive border border-destructive/30 bg-background rounded-lg px-3 py-2 hover:bg-destructive/10 transition-colors"
        >
          <Trash2 className="w-4 h-4" />
          Clear All Sessions
        </button>
      </footer>
    </aside>
  )
}
