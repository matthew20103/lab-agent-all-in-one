export interface RedisConfig {
  system_prompt: string
  connection_method: string
  gateway_url: string
  gateway_api_key: string
  mcp_api_key: string
  vision_capable: boolean
}

export interface McpServer {
  slug: string
  enabled: boolean
}

export interface McpServersConfig {
  mcp_gateway_url: string
  servers: McpServer[]
  // Where `servers` came from: saved in the MCP Servers tab, the old comma-separated
  // key, the backend's PORTKEY_MCP_SERVER_SLUGS env default, or nothing at all.
  source: 'saved' | 'legacy' | 'env' | 'none'
}

export interface McpTool {
  name: string
  description: string
}

export type McpTestResult =
  | { ok: true; latency_ms: number; tools: McpTool[] }
  | { ok: false; error: string }

// A2A sub-agent registered in the AI Gateway; becomes the tool `a2a__{slug}`.
export interface A2aAgent {
  slug: string
  url: string
  enabled: boolean
  // Card URL override. Empty: the card is read from `{url}/.well-known/agent-card.json`.
  // Set: read from here instead (e.g. the agent's own card, when the gateway only serves
  // a stub). Calls always go through `url`.
  card_url?: string
}

export interface A2aAgentsConfig {
  agents: A2aAgent[]
}

export type A2aTestResult =
  | {
      ok: true
      latency_ms: number
      card_source: 'card_url' | 'gateway'
      name: string
      description: string
      protocol_version: string
      endpoints: string[]
      skills: { name: string; description: string }[]
    }
  | { ok: false; error: string }

export interface SessionMeta {
  key: string
  ttl: number
}

export interface ChatMessage {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  tool_calls?: Array<{ function: { name: string } }>
}
