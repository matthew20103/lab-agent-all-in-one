'use client'

import { useCallback } from 'react'
import { AGENT_WSS_URL } from '@/lib/constants'
import type { StreamCallbacks } from '@/lib/types'

export function useWebSocketTransport() {
  const send = useCallback(
    (
      token: string,
      payload: Record<string, unknown>,
      callbacks: StreamCallbacks,
    ): Promise<void> => {
      return new Promise((resolve) => {
        // token is the full "Scheme value" (e.g. "Bearer <jwt>" or "Basic <base64>") —
        // the backend's /ws handler reads it verbatim from this query param.
        const url = `${AGENT_WSS_URL}?access_token=${encodeURIComponent(token)}`
        const ws = new WebSocket(url)
        let sessionId = ''

        ws.onmessage = (e) => {
          try {
            const msg = JSON.parse(e.data)
            switch (msg.event) {
              case 'connected':
                ws.send(JSON.stringify({ payload }))
                break
              case 'agent_thinking':
                callbacks.onThinking(msg.payload?.chunk ?? '')
                break
              case 'agent_stream':
                callbacks.onContent(msg.payload?.chunk ?? '')
                break
              case 'trace_id':
                callbacks.onTraceId(msg.payload?.trace_id ?? '')
                break
              case 'routing_info':
                callbacks.onRoutingInfo(msg.payload?.info ?? '')
                break
              case 'agent_complete': {
                const p = msg.payload
                if (p && typeof p === 'object') {
                  sessionId = p.id ?? ''
                } else if (typeof p === 'string') {
                  sessionId = p
                }
                ws.close()
                callbacks.onDone(sessionId)
                resolve()
                break
              }
              case 'error':
                callbacks.onError(msg.payload ?? 'WebSocket error')
                ws.close()
                resolve()
                break
            }
          } catch {
            // skip parse errors
          }
        }

        ws.onerror = () => {
          callbacks.onError('WebSocket connection failed')
          resolve()
        }

        ws.onclose = () => {
          resolve()
        }
      })
    },
    [],
  )

  return { send }
}
