'use client'

import { useCallback } from 'react'
import { AGENT_STREAM_URL } from '@/lib/constants'
import type { StreamCallbacks } from '@/lib/types'

export function useSSETransport() {
  const send = useCallback(
    async (
      token: string,
      payload: Record<string, unknown>,
      callbacks: StreamCallbacks,
    ) => {
      const resp = await fetch(AGENT_STREAM_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: token,
        },
        body: JSON.stringify(payload),
      })

      if (!resp.ok) {
        callbacks.onError(`HTTP ${resp.status}`)
        return
      }

      const reader = resp.body!.getReader()
      const decoder = new TextDecoder()
      let buffer = ''
      let sessionId = ''

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split('\n')
        buffer = lines.pop()!

        for (const line of lines) {
          if (!line.startsWith('data: ')) continue
          const data = line.slice(6).trim()
          if (data === '[DONE]') {
            callbacks.onDone(sessionId)
            return
          }
          try {
            const obj = JSON.parse(data)
            if (obj.type === 'thinking') callbacks.onThinking(obj.chunk ?? '')
            else if (obj.type === 'trace_id') callbacks.onTraceId(obj.chunk ?? '')
            else if (obj.type === 'session_id') sessionId = obj.chunk ?? ''
            else if (obj.type === 'routing_info') callbacks.onRoutingInfo(obj.info ?? '')
            else callbacks.onContent(obj.chunk ?? '')
          } catch {
            // skip malformed lines
          }
        }
      }

      callbacks.onDone(sessionId)
    },
    [],
  )

  return { send }
}
