export type Protocol = 'websocket' | 'sse' | 'rest'
export type TaskType = 'writing' | 'coding'

export interface Attachment {
  name: string
  status: 'uploading' | 'ok' | 'unsupported' | 'error'
  error?: string
}

export interface ChatMessage {
  role: 'user' | 'assistant'
  content: string
  attachments?: Attachment[]
  // Epoch ms, shown as HH:MM under the bubble
  createdAt?: number
  thinking?: string
  traceId?: string | null
  routingInfo?: string | null
  feedbackId?: string | null
  lastFbValue?: number | null
  userInfo?: { id: string; email: string; name: string } | null
}

export interface StreamCallbacks {
  onThinking: (chunk: string) => void
  onContent: (chunk: string) => void
  onTraceId: (id: string) => void
  onRoutingInfo: (info: string) => void
  onDone: (sessionId: string) => void
  onError: (msg: string) => void
}
