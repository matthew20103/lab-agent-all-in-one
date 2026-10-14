'use client'

import { useState } from 'react'
import useSWR from 'swr'
import { CheckCircle, ChevronDown, ChevronRight, Loader2, Plus, Save, Search, Trash2, XCircle } from 'lucide-react'
import { defaultCardUrl, slugError, slugFromUrl, urlError } from '@/lib/a2a'
import type { A2aAgent, A2aAgentsConfig, A2aTestResult } from '@/lib/types'

const fetcher = (url: string) => fetch(url).then((r) => r.json())

type TestState = { status: 'testing' } | ({ status: 'done' } & A2aTestResult)

const inputClass =
  'w-full bg-background border border-input rounded-lg px-3 py-2 text-sm font-mono focus:border-transparent focus:outline-none focus:ring-2 focus:ring-ring'
const secondaryButtonClass =
  'flex items-center gap-1.5 text-sm border border-border rounded-lg px-3 py-1.5 hover:bg-accent transition-colors disabled:opacity-50 disabled:pointer-events-none'

const hostOf = (url: string) => {
  try {
    return new URL(url).host
  } catch {
    return ''
  }
}

export function A2aAgents() {
  const { data, mutate } = useSWR<A2aAgentsConfig>('/api/a2a-agents', fetcher, { refreshInterval: 10000 })
  // Drafts stay null until edited, so the 10 s refresh never overwrites unsaved changes.
  const [draft, setDraft] = useState<A2aAgent[] | null>(null)
  const [newUrl, setNewUrl] = useState('')
  const [newCardUrl, setNewCardUrl] = useState('')
  const [newSlug, setNewSlug] = useState('')
  const [slugTouched, setSlugTouched] = useState(false)
  const [addError, setAddError] = useState<string | null>(null)
  const [tests, setTests] = useState<Record<string, TestState>>({})
  const [expanded, setExpanded] = useState<Record<string, boolean>>({})
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  if (!data) return <div className="text-muted-foreground text-sm">Loading...</div>

  const agents = draft ?? data.agents
  const dirty = JSON.stringify(agents) !== JSON.stringify(data.agents)
  const enabledCount = agents.filter((a) => a.enabled).length
  const isSaved = (a: A2aAgent) =>
    data.agents.some((s) => s.slug === a.slug && s.url === a.url && (s.card_url ?? '') === (a.card_url ?? ''))

  const toggle = (slug: string) => setDraft(agents.map((a) => (a.slug === slug ? { ...a, enabled: !a.enabled } : a)))
  const remove = (slug: string) => setDraft(agents.filter((a) => a.slug !== slug))
  // An empty card URL is dropped rather than stored as "", so clearing it doesn't count as a change.
  const setCardUrl = (slug: string, value: string) =>
    setDraft(
      agents.map((a) => {
        if (a.slug !== slug) return a
        const { card_url: _, ...rest } = a
        return value ? { ...rest, card_url: value } : rest
      }),
    )

  const add = () => {
    const url = newUrl.trim().replace(/\/+$/, '')
    const cardUrl = newCardUrl.trim()
    const slug = newSlug.trim()
    const err =
      urlError(url) ??
      (cardUrl ? urlError(cardUrl, 'card URL override') : null) ??
      slugError(slug, agents.map((a) => a.slug))
    setAddError(err)
    if (err) return
    setDraft([...agents, { slug, url, enabled: true, ...(cardUrl ? { card_url: cardUrl } : {}) }])
    setNewUrl('')
    setNewCardUrl('')
    setNewSlug('')
    setSlugTouched(false)
  }

  const runTest = async (slug: string) => {
    setTests((t) => ({ ...t, [slug]: { status: 'testing' } }))
    let result: A2aTestResult
    try {
      const res = await fetch('/api/a2a-agents/test', {
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
    if (result.ok) setExpanded((x) => ({ ...x, [slug]: true }))
  }

  const handleSave = async () => {
    setSaving(true)
    setSaveError(null)
    try {
      const res = await fetch('/api/a2a-agents', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agents }),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        setSaveError(body.error ?? `Save failed (HTTP ${res.status})`)
        return
      }
      await mutate({ agents }, false)
      setDraft(null)
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
      <div>
        <h2 className="text-lg font-semibold">Sub-agents</h2>
        <p className="text-sm text-muted-foreground mt-1">
          A2A agents registered in the AI Gateway. Each enabled one becomes a tool the agent can delegate to.{' '}
          {enabledCount} of {agents.length} enabled.
        </p>
      </div>

      <section className="space-y-2">
        {!agents.length ? (
          <div className="text-muted-foreground text-sm py-8 text-center border border-dashed border-border rounded-lg">
            No sub-agents yet. Add one below.
          </div>
        ) : (
          <ul className="border border-border rounded-lg divide-y divide-border">
            {agents.map((a) => {
              const test = tests[a.slug]
              const passed = test?.status === 'done' && test.ok ? test : null
              const isOpen = expanded[a.slug] && !!passed
              const offGateway = passed?.endpoints.some((u) => hostOf(u) && hostOf(u) !== hostOf(a.url))
              return (
                <li key={a.slug} className="px-4 py-3">
                  <div className="flex flex-wrap items-center gap-3">
                    <button
                      type="button"
                      role="switch"
                      aria-checked={a.enabled}
                      aria-label={`${a.enabled ? 'Disable' : 'Enable'} ${a.slug}`}
                      onClick={() => toggle(a.slug)}
                      className={`relative w-9 h-5 shrink-0 rounded-full transition-colors ${a.enabled ? 'bg-primary' : 'bg-muted'}`}
                    >
                      <span
                        className={`absolute top-0.5 left-0.5 w-4 h-4 rounded-full bg-white shadow transition-transform ${
                          a.enabled ? 'translate-x-4' : ''
                        }`}
                      />
                    </button>
                    <div className={`min-w-0 flex-1 ${a.enabled ? '' : 'text-muted-foreground'}`}>
                      <p className="font-mono text-sm truncate">a2a__{a.slug}</p>
                      <p className="text-xs text-muted-foreground truncate" title={a.url}>
                        {a.url}
                      </p>
                    </div>

                    {test?.status === 'testing' && (
                      <span className="flex items-center gap-1 text-xs text-muted-foreground">
                        <Loader2 className="w-3.5 h-3.5 animate-spin" />
                        Testing…
                      </span>
                    )}
                    {passed && (
                      <button
                        type="button"
                        onClick={() => setExpanded((x) => ({ ...x, [a.slug]: !x[a.slug] }))}
                        className="flex items-center gap-1 text-xs text-emerald-600 dark:text-emerald-400 hover:underline"
                      >
                        <CheckCircle className="w-3.5 h-3.5" />
                        {passed.name} · {passed.latency_ms} ms
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
                      onClick={() => runTest(a.slug)}
                      disabled={!isSaved(a) || test?.status === 'testing'}
                      title={isSaved(a) ? undefined : 'Save first — tests use the saved URL'}
                      className={secondaryButtonClass}
                    >
                      <Search className="w-3.5 h-3.5" />
                      Test
                    </button>
                    <button
                      onClick={() => remove(a.slug)}
                      aria-label={`Remove ${a.slug}`}
                      className="p-1.5 rounded-md text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-colors"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>

                  <div className="mt-2 ml-12">
                    <label className="mb-1 block text-[11px] text-muted-foreground" htmlFor={`card-url-${a.slug}`}>
                      Card URL override (optional; leave empty to use the agent URL)
                    </label>
                    <input
                      id={`card-url-${a.slug}`}
                      type="text"
                      value={a.card_url ?? ''}
                      onChange={(e) => setCardUrl(a.slug, e.target.value)}
                      placeholder={defaultCardUrl(a.url)}
                      className={`${inputClass} py-1.5 text-xs`}
                    />
                  </div>

                  {test?.status === 'done' && !test.ok && (
                    <p className="mt-1.5 ml-12 text-xs text-destructive break-words">{test.error}</p>
                  )}

                  {isOpen && passed && (
                    <div className="mt-2 ml-12 space-y-1.5 text-xs">
                      <p className="text-muted-foreground">
                        Card read from{' '}
                        {passed.card_source === 'card_url' ? 'the card URL override' : 'the agent URL (no override set)'}.
                      </p>
                      {passed.card_source === 'gateway' && !passed.skills.length && passed.name === '(unnamed)' && (
                        <p className="text-amber-600 dark:text-amber-400">
                          The agent URL returned a stub card with no name or skills, so the agent won&apos;t know what
                          this sub-agent does. Set a card URL override pointing at the agent&apos;s own agent-card.json.
                        </p>
                      )}
                      {passed.description && <p className="text-muted-foreground">{passed.description}</p>}
                      <p className="text-muted-foreground">A2A protocol {passed.protocol_version}</p>
                      {offGateway && (
                        <p className="text-amber-600 dark:text-amber-400">
                          The card advertises an endpoint on another host; the backend sends calls to the gateway URL
                          above instead.
                        </p>
                      )}
                      {passed.skills.length === 0 ? (
                        <p className="text-muted-foreground">No skills listed on the card.</p>
                      ) : (
                        <ul className="space-y-1">
                          {passed.skills.map((s) => (
                            <li key={s.name}>
                              <span className="font-medium">{s.name}</span>
                              {s.description && <span className="text-muted-foreground"> — {s.description}</span>}
                            </li>
                          ))}
                        </ul>
                      )}
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
        )}

        <div className="space-y-2 pt-1">
          <input
            type="text"
            value={newUrl}
            onChange={(e) => {
              setNewUrl(e.target.value)
              if (!slugTouched) setNewSlug(slugFromUrl(e.target.value.trim()))
              setAddError(null)
            }}
            placeholder="Agent URL from the AI Gateway, e.g. http://gateway-host/v1/agent/db-agent"
            className={inputClass}
          />
          <input
            type="text"
            value={newCardUrl}
            onChange={(e) => {
              setNewCardUrl(e.target.value)
              setAddError(null)
            }}
            placeholder={`Card URL override (optional). Empty: ${
              urlError(newUrl.trim()) ? '{agent URL}/.well-known/agent-card.json' : defaultCardUrl(newUrl)
            }`}
            className={inputClass}
          />
          <div className="flex gap-2">
            <input
              type="text"
              value={newSlug}
              onChange={(e) => {
                setNewSlug(e.target.value)
                setSlugTouched(true)
                setAddError(null)
              }}
              onKeyDown={(e) => e.key === 'Enter' && add()}
              placeholder="Short name (becomes the tool name)"
              className={inputClass}
            />
            <button onClick={add} className={`${secondaryButtonClass} shrink-0`}>
              <Plus className="w-3.5 h-3.5" />
              Add
            </button>
          </div>
          {addError && <p className="text-xs text-destructive">{addError}</p>}
        </div>
      </section>

      <div className="flex flex-wrap items-center gap-3">
        <button
          onClick={handleSave}
          disabled={!dirty || saving}
          className="flex items-center gap-2 bg-primary text-primary-foreground px-4 py-2 rounded-lg text-sm font-medium hover:bg-primary/90 transition-colors disabled:opacity-50 disabled:pointer-events-none"
        >
          {saved ? <CheckCircle className="w-4 h-4" /> : <Save className="w-4 h-4" />}
          {saved ? 'Saved' : saving ? 'Saving…' : 'Save'}
        </button>
        {dirty && (
          <>
            <button
              onClick={() => {
                setDraft(null)
                setSaveError(null)
              }}
              className="text-sm text-muted-foreground hover:text-foreground"
            >
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
