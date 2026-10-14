import type { McpServer } from './types'

// The backend builds {mcp_gateway_url}/{slug}/mcp, so a slug must be one safe path segment.
export const MCP_SLUG_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

export function slugError(slug: string, existing: string[]): string | null {
  if (!slug) return 'Enter a server slug.'
  if (!MCP_SLUG_PATTERN.test(slug)) return 'Use letters, digits, ".", "_" or "-", starting with a letter or digit.'
  if (existing.includes(slug)) return `"${slug}" is already in the list.`
  return null
}

export function validateMcpConfig(
  body: unknown,
): { servers: McpServer[]; mcp_gateway_url: string } | { error: string } {
  if (!body || typeof body !== 'object') return { error: 'Expected a JSON object.' }
  const { servers, mcp_gateway_url } = body as Record<string, unknown>

  if (typeof mcp_gateway_url !== 'string') return { error: 'mcp_gateway_url must be a string.' }
  const url = mcp_gateway_url.trim()
  if (url) {
    try {
      const { protocol } = new URL(url)
      if (protocol !== 'http:' && protocol !== 'https:') return { error: 'MCP Gateway URL must be http(s).' }
    } catch {
      return { error: 'MCP Gateway URL is not a valid URL.' }
    }
  }

  if (!Array.isArray(servers)) return { error: 'servers must be an array.' }
  const clean: McpServer[] = []
  for (const s of servers) {
    if (!s || typeof s !== 'object') return { error: 'Each server must be an object.' }
    const { slug, enabled } = s as Record<string, unknown>
    if (typeof slug !== 'string' || typeof enabled !== 'boolean') {
      return { error: 'Each server needs a string slug and a boolean enabled.' }
    }
    const err = slugError(slug.trim(), clean.map((c) => c.slug))
    if (err) return { error: err }
    clean.push({ slug: slug.trim(), enabled })
  }
  return { servers: clean, mcp_gateway_url: url }
}
