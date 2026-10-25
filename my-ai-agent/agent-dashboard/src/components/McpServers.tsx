'use client'

import { useState } from 'react'
import useSWR from 'swr'
import {
  CheckCircle,
  ChevronDown,
  ChevronRight,
  Info,
  Loader2,
  Plus,
  PlugZap,
  Save,
  Trash2,
  XCircle,
} from 'lucide-react'
import { slugError } from '@/lib/mcp'
import type { McpServer, McpServersConfig, McpTestResult, RedisConfig } from '@/lib/types'

const fetcher = (url: string) => fetch(url).then((r) => r.json())

type TestState = { status: 'testing' } | ({ status: 'done' } & McpTestResult)

const SOURCE_NOTICE: Record<McpServersConfig['source'], string | null> = {
  saved: null,
  legacy: 'Loaded from the old comma-separated setting. Saving here moves it to the new format.',
  env: "Nothing saved yet — showing the backend's PORTKEY_MCP_SERVER_SLUGS default.",
  none: null,
}

const inputClass =
  'w-full bg-background border border-input rounded-md px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ring'
const secondaryButtonClass =
  'flex items-center gap-1.5 text-sm border border-border rounded-md px-3 py-1.5 hover:bg-accent transition-colors disabled:opacity-50 disabled:pointer-events-none'

export function McpServers() {
  const { data, mutate } = useSWR<McpServersConfig>('/api/mcp-servers', fetcher, { refreshInterval: 10000 })
  const { data: config, mutate: mutateConfig } = useSWR<RedisConfig>('/api/config', fetcher, {
    refreshInterval: 10000,
  })
  // Drafts stay null until edited, so the 10 s refresh never overwrites unsaved changes.
  const [draftUrl, setDraftUrl] = useState<string | null>(null)
  const [draftServers, setDraftServers] = useState<McpServer[] | null>(null)
  const [draftMcpApiKey, setDraftMcpApiKey] = useState<string | null>(null)
  const [newSlug, setNewSlug] = useState('')
  const [addError, setAddError] = useState<string | null>(null)
  const [tests, setTests] = useState<Record<string, TestState>>({})
  const [expanded, setExpanded] = useState<Record<string, boolean>>({})
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  if (!data || !config) return <div className="text-muted-foreground text-sm">Loading...</div>

  const url = draftUrl ?? data.mcp_gateway_url
  const servers = draftServers ?? data.servers
  const mcpApiKey = draftMcpApiKey ?? config.mcp_api_key
  const urlDirty = url.trim() !== data.mcp_gateway_url
  const mcpApiKeyDirty = mcpApiKey !== config.mcp_api_key
  const dirty = urlDirty || mcpApiKeyDirty || JSON.stringify(servers) !== JSON.stringify(data.servers)
  const enabledCount = servers.filter((s) => s.enabled).length
  const notice = SOURCE_NOTICE[data.source]
  const testBlockedReason = urlDirty
    ? 'Save the gateway URL first — tests use the saved URL'
    : !url.trim()
      ? 'Set an MCP Gateway URL first'
      : mcpApiKeyDirty
        ? 'Save the MCP API key first — tests use the saved key'
        : null

  const toggle = (slug: string) =>
    setDraftServers(servers.map((s) => (s.slug === slug ? { ...s, enabled: !s.enabled } : s)))

  const remove = (slug: string) => setDraftServers(servers.filter((s) => s.slug !== slug))

  const add = () => {
    const slug = newSlug.trim()
    const err = slugError(slug, servers.map((s) => s.slug))
    setAddError(err)
    if (err) return
    setDraftServers([...servers, { slug, enabled: true }])
    setNewSlug('')
  }

  const runTest = async (slug: string) => {
    setTests((t) => ({ ...t, [slug]: { status: 'testing' } }))
    let result: McpTestResult
    try {
      const res = await fetch('/api/mcp-servers/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ slug }),
      })
      const body = await res.json()
      result = res.ok ? body : { ok: false, error: body.error ?? `HTTP ${res.status}` }
    } catch (e) {
      result = { ok: false, error: e instanceof Error ? e.message : 'Request failed' }
    }
    setTests((t) => ({ ...t, [slug]: { status: 'done', ...result } }))
  }

  const discard = () => {
    setDraftUrl(null)
    setDraftServers(null)
    setDraftMcpApiKey(null)
    setSaveError(null)
  }

  const handleSave = async () => {
    setSaving(true)
    setSaveError(null)
    const payload = { mcp_gateway_url: url.trim(), servers }
    const trimmedMcpApiKey = mcpApiKey.trim()
    try {
      const [mcpRes, configRes] = await Promise.all([
        fetch('/api/mcp-servers', {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        }),
        fetch('/api/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ mcp_api_key: trimmedMcpApiKey }),
        }),
      ])
      if (!mcpRes.ok) {
        const body = await mcpRes.json().catch(() => ({}))
        setSaveError(body.error ?? `Save failed (HTTP ${mcpRes.status})`)
        return
      }
      if (!configRes.ok) {
        setSaveError(`Save failed (HTTP ${configRes.status})`)
        return
      }
      await mutate({ ...payload, source: 'saved' }, false)
      await mutateConfig({ ...config, mcp_api_key: trimmedMcpApiKey }, false)
      setDraftUrl(null)
      setDraftServers(null)
      setDraftMcpApiKey(null)
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
    } catch (e) {
      setSaveError(e instanceof Error ? e.message : 'Save failed')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="max-w-3xl space-y-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold">MCP Servers</h2>
          <p className="text-sm text-muted-foreground mt-1">
            {enabledCount} of {servers.length} enabled · changes apply to the next message after you save.
          </p>
        </div>
        <button
          onClick={() => servers.forEach((s) => runTest(s.slug))}
          disabled={!servers.length || !!testBlockedReason}
          title={testBlockedReason ?? undefined}
          className={secondaryButtonClass}
        >
          <PlugZap className="w-3.5 h-3.5" />
          Test all
        </button>
      </div>

      {notice && (
        <div className="flex items-start gap-2 text-sm text-muted-foreground border border-border rounded-md px-3 py-2">
          <Info className="w-4 h-4 mt-0.5 shrink-0" />
          {notice}
        </div>
      )}

      <section>
        <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wide block mb-2">
          MCP Gateway URL
        </label>
        <input
          type="text"
          value={url}
          onChange={(e) => setDraftUrl(e.target.value)}
          placeholder="http://gateway-host:8788 (often a different port than the chat gateway)"
          className={inputClass}
        />
        <p className="text-xs text-muted-foreground mt-1.5">
          Each server is reached at <code className="font-mono">{'{URL}/{slug}/mcp'}</code>. Use
          the AI Gateway&apos;s own MCP endpoint for production, or point this directly at an MCP
          hub (bypassing the gateway entirely) for local/lab testing.
        </p>
      </section>

      <section>
        <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wide block mb-2">
          MCP API Key
        </label>
        <input
          type="password"
          value={mcpApiKey}
          onChange={(e) => setDraftMcpApiKey(e.target.value)}
          placeholder="Sent as x-portkey-api-key to every MCP server above"
          className={inputClass}
        />
        <p className="text-xs text-muted-foreground mt-1.5">
          Separate from the Sidebar&apos;s Gateway API Key, which is for LLM chat only — this key
          is used only for MCP tool-call auth. Leave blank to fall back to the Gateway API Key.
        </p>
      </section>

      <section className="space-y-2">
        <label className="text-xs font-semibold text-muted-foreground uppercase tracking-wide block">
          Servers
        </label>

        {!servers.length ? (
          <div className="text-muted-foreground text-sm py-8 text-center border border-dashed border-border rounded-lg">
            No MCP servers yet. Add one below.
          </div>
        ) : (
          <ul className="border border-border rounded-lg divide-y divide-border">
            {servers.map((s) => {
              const test = tests[s.slug]
              const passed = test?.status === 'done' && test.ok ? test : null
              const isOpen = expanded[s.slug] && !!passed
              return (
                <li key={s.slug} className="px-4 py-3">
                  <div className="flex flex-wrap items-center gap-3">
                    <button
                      type="button"
                      role="switch"
                      aria-checked={s.enabled}
                      aria-label={`${s.enabled ? 'Disable' : 'Enable'} ${s.slug}`}
                      onClick={() => toggle(s.slug)}
                      className={`relative w-9 h-5 shrink-0 rounded-full transition-colors ${
                        s.enabled ? 'bg-primary' : 'bg-muted'
                      }`}
                    >
                      <span
                        className={`absolute top-0.5 left-0.5 w-4 h-4 rounded-full bg-white shadow transition-transform ${
                          s.enabled ? 'translate-x-4' : ''
                        }`}
                      />
                    </button>

                    <span
                      className={`font-mono text-sm flex-1 min-w-0 truncate ${
                        s.enabled ? '' : 'text-muted-foreground'
                      }`}
                    >
                      {s.slug}
                    </span>

                    {!test && <span className="text-xs text-muted-foreground">Not tested</span>}
                    {test?.status === 'testing' && (
                      <span className="flex items-center gap-1 text-xs text-muted-foreground">
                        <Loader2 className="w-3.5 h-3.5 animate-spin" />
                        Testing…
                      </span>
                    )}
                    {passed && (
                      <button
                        type="button"
                        onClick={() => setExpanded((x) => ({ ...x, [s.slug]: !x[s.slug] }))}
                        className="flex items-center gap-1 text-xs text-emerald-600 dark:text-emerald-400 hover:underline"
                      >
                        <CheckCircle className="w-3.5 h-3.5" />
                        {passed.tools.length} tool{passed.tools.length === 1 ? '' : 's'} · {passed.latency_ms} ms
                        {isOpen ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />}
                      </button>
                    )}
                    {test?.status === 'done' && !test.ok && (
                      <span className="flex items-center gap-1 text-xs text-destructive">
                        <XCircle className="w-3.5 h-3.5" />
                        Failed
                      </span>
                    )}

                    <button
                      onClick={() => runTest(s.slug)}
                      disabled={!!testBlockedReason || test?.status === 'testing'}
                      title={testBlockedReason ?? undefined}
                      className={secondaryButtonClass}
                    >
                      Test
                    </button>
                    <button
                      onClick={() => remove(s.slug)}
                      aria-label={`Remove ${s.slug}`}
                      className="p-1.5 rounded-md text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-colors"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>

                  {test?.status === 'done' && !test.ok && (
                    <p className="mt-1.5 ml-12 text-xs text-destructive break-words">{test.error}</p>
                  )}

                  {isOpen && passed && (
                    <ul className="mt-2 ml-12 space-y-1.5">
                      {passed.tools.length === 0 && (
                        <li className="text-xs text-muted-foreground">This server exposes no tools.</li>
                      )}
                      {passed.tools.map((t) => (
                        <li key={t.name} className="text-xs">
                          <span className="font-mono font-medium">{t.name}</span>
                          {t.description && (
                            <span className="text-muted-foreground line-clamp-2"> — {t.description}</span>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}
                </li>
              )
            })}
          </ul>
        )}

        <div>
          <div className="flex gap-2">
            <input
              type="text"
              value={newSlug}
              onChange={(e) => {
                setNewSlug(e.target.value)
                setAddError(null)
              }}
              onKeyDown={(e) => e.key === 'Enter' && add()}
              placeholder="New server slug, e.g. agent-memory"
              className={inputClass}
            />
            <button onClick={add} className={`${secondaryButtonClass} shrink-0`}>
              <Plus className="w-3.5 h-3.5" />
              Add
            </button>
          </div>
          {addError && <p className="text-xs text-destructive mt-1.5">{addError}</p>}
        </div>
      </section>

      <div className="flex flex-wrap items-center gap-3">
        <button
          onClick={handleSave}
          disabled={!dirty || saving}
          className="flex items-center gap-2 bg-primary text-primary-foreground px-4 py-2 rounded-md text-sm font-medium hover:bg-primary/90 transition-colors disabled:opacity-50 disabled:pointer-events-none"
        >
          {saved ? <CheckCircle className="w-4 h-4" /> : <Save className="w-4 h-4" />}
          {saved ? 'Saved' : saving ? 'Saving…' : 'Save'}
        </button>
        {dirty && (
          <>
            <button onClick={discard} className="text-sm text-muted-foreground hover:text-foreground">
              Discard
            </button>
            <span className="text-xs text-muted-foreground">Unsaved changes</span>
          </>
        )}
        {saveError && <span className="text-xs text-destructive">{saveError}</span>}
      </div>
    </div>
  )
}
