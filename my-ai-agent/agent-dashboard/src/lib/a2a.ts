import type { A2aAgent } from './types'

// The slug becomes the tool name `a2a__{slug}`, which must match ^[a-zA-Z0-9_-]{1,64}$.
export const A2A_SLUG_PATTERN = /^[A-Za-z0-9_-]{1,48}$/

// Default slug: the URL's last path segment, e.g. .../v1/agent/db-agent -> "db-agent".
export function slugFromUrl(url: string): string {
  try {
    const last = new URL(url).pathname.split('/').filter(Boolean).pop() ?? ''
    return last.replace(/[^A-Za-z0-9_-]/g, '-').slice(0, 48)
  } catch {
    return ''
  }
}

// Where the card is read from when no override is set (same rule as the backend).
export function defaultCardUrl(agentUrl: string): string {
  return `${agentUrl.trim().replace(/\/+$/, '')}/.well-known/agent-card.json`
}

export function urlError(url: string, label = 'agent URL'): string | null {
  try {
    const { protocol } = new URL(url)
    return protocol === 'http:' || protocol === 'https:' ? null : `The ${label} must be http(s).`
  } catch {
    return `Enter a valid ${label}.`
  }
}

export function slugError(slug: string, existing: string[]): string | null {
  if (!slug) return 'Enter a short name for the agent.'
  if (!A2A_SLUG_PATTERN.test(slug)) return 'Use letters, digits, "_" or "-" (up to 48 characters).'
  if (existing.includes(slug)) return `"${slug}" is already in the list.`
  return null
}

export function validateA2aConfig(body: unknown): { agents: A2aAgent[] } | { error: string } {
  if (!body || typeof body !== 'object' || !Array.isArray((body as { agents?: unknown }).agents)) {
    return { error: 'Expected { agents: [...] }.' }
  }
  const clean: A2aAgent[] = []
  for (const a of (body as { agents: unknown[] }).agents) {
    if (!a || typeof a !== 'object') return { error: 'Each agent must be an object.' }
    const { slug, url, enabled, card_url } = a as Record<string, unknown>
    if (typeof slug !== 'string' || typeof url !== 'string' || typeof enabled !== 'boolean') {
      return { error: 'Each agent needs a string slug and url and a boolean enabled.' }
    }
    if (card_url !== undefined && typeof card_url !== 'string') return { error: 'card_url must be a string.' }
    const cardUrl = (card_url ?? '').trim()
    const err =
      slugError(slug.trim(), clean.map((c) => c.slug)) ??
      urlError(url.trim()) ??
      (cardUrl ? urlError(cardUrl, 'card URL override') : null)
    if (err) return { error: err }
    clean.push({
      slug: slug.trim(),
      url: url.trim().replace(/\/+$/, ''),
      enabled,
      ...(cardUrl ? { card_url: cardUrl } : {}),
    })
  }
  return { agents: clean }
}
