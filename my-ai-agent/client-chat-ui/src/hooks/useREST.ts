'use client'

import { useCallback } from 'react'
import { AGENT_REST_URL } from '@/lib/constants'
import type { StreamCallbacks } from '@/lib/types'

export function useRESTTransport() {
  const send = useCallback(
    async (
      token: string,
      payload: Record<string, unknown>,
      callbacks: StreamCallbacks,
    ) => {
      const resp = await fetch(AGENT_REST_URL, {
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

      const data = await resp.json()
      if (data.thinking) callbacks.onThinking(data.thinking)
      if (data.trace_id) callbacks.onTraceId(data.trace_id)
      if (data.routing_info) callbacks.onRoutingInfo(data.routing_info)
      callbacks.onContent(data.response ?? '')
      callbacks.onDone(data.session_id ?? '')
    },
    [],
  )

  return { send }
}
