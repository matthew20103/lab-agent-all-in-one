'use client'

import { useCallback, useRef, useState } from 'react'
import { useSession, signOut } from 'next-auth/react'
import { useWebSocketTransport } from './useWebSocket'
import { useSSETransport } from './useSSE'
import { useRESTTransport } from './useREST'
import { AGENT_UPLOAD_URL } from '@/lib/constants'
import type { Protocol, TaskType, ChatMessage, Attachment } from '@/lib/types'

// Distinguishable error strings the transports surface for an expired/invalid
// token — see useREST.ts/useSSE.ts's `HTTP ${status}` and useWebSocket.ts's
// forwarding of agent-backend main.py's /ws auth-failure payloads.
const isAuthError = (msg: string) => msg === 'HTTP 401' || msg === 'Invalid Token' || msg === 'Missing Token'

export function useAgentStream(protocol: Protocol, taskType: TaskType) {
  const { data: session, update } = useSession()
  const tokenCacheRef = useRef<string | null>(null)
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [isStreaming, setIsStreaming] = useState(false)

  // Keep a ref that always holds the latest sessionId so sendMessage
  // can read it without being stale, regardless of closure capture timing.
  const sessionIdRef = useRef<string | null>(null)

  const { send: sendWS } = useWebSocketTransport()
  const { send: sendSSE } = useSSETransport()
  const { send: sendREST } = useRESTTransport()

  const getToken = useCallback(async (): Promise<string> => {
    // Returns the full Authorization header value ("Bearer <token>" for CyberArk Identity,
    // "Basic <base64>" for Basic Auth) — set during login, see lib/auth.ts.
    const accessToken = (session as Record<string, unknown> | null)?.accessToken as string | undefined
    if (accessToken) {
      const authMethod = (session as Record<string, unknown> | null)?.authMethod as string | undefined
      const header = authMethod === 'basic' ? accessToken : `Bearer ${accessToken}`
      tokenCacheRef.current = header
      return header
    }
    // Fallback: cached header from previous call
    if (tokenCacheRef.current) return tokenCacheRef.current
    throw new Error('No access token available — please sign in')
  }, [session])

  // The backend accepts any session_id and /api/v1/upload creates the session if it's
  // missing, so files can be uploaded before the first message under a client-made ID.
  const ensureSessionId = useCallback((): string => {
    if (!sessionIdRef.current) {
      sessionIdRef.current = crypto.randomUUID()
      setSessionId(sessionIdRef.current)
    }
    return sessionIdRef.current
  }, [])

  const uploadFile = useCallback(async (file: File, sid: string, token: string): Promise<Attachment> => {
    try {
      const form = new FormData()
      form.append('file', file, file.name)
      form.append('session_id', sid)
      const resp = await fetch(AGENT_UPLOAD_URL, { method: 'POST', headers: { Authorization: token }, body: form })
      if (!resp.ok) return { name: file.name, status: 'error', error: `Upload failed (HTTP ${resp.status})` }
      const data = await resp.json().catch(() => null)
      return { name: file.name, status: data?.status === 'unsupported_model' ? 'unsupported' : 'ok' }
    } catch (e) {
      return { name: file.name, status: 'error', error: String(e) }
    }
  }, [])

  const sendMessage = useCallback(
    async (text: string, files: File[] = []): Promise<Attachment[]> => {
      if (isStreaming) return []
      // Covers the upload phase too, so the composer stays locked until the reply is saved.
      setIsStreaming(true)

      const userIndex = messages.length
      const attachments: Attachment[] = files.map((f) => ({ name: f.name, status: 'uploading' }))
      const userMsg: ChatMessage = {
        role: 'user',
        content: text,
        createdAt: Date.now(),
        ...(files.length ? { attachments } : {}),
      }
      setMessages((prev) => [...prev, userMsg])

      if (files.length) {
        const sid = ensureSessionId()
        let token: string | null = null
        let tokenError = ''
        try {
          token = await getToken()
        } catch (e) {
          tokenError = String(e)
        }
        // One at a time: each upload reads, appends to, and rewrites session history.
        for (let i = 0; i < files.length; i++) {
          attachments[i] = token
            ? await uploadFile(files[i], sid, token)
            : { name: files[i].name, status: 'error', error: tokenError }
          const snapshot = [...attachments]
          setMessages((prev) => {
            const next = [...prev]
            next[userIndex] = { ...next[userIndex], attachments: snapshot }
            return next
          })
        }
      }

      if (!text) {
        setIsStreaming(false)
        return attachments
      }

      let thinking = ''
      let content = ''
      let traceId: string | null = null
      let routingInfo: string | null = null

      // Read from ref — always current, never stale from closure
      const currentSessionId = sessionIdRef.current
      const assistantIndex = messages.length + 1

      const updateAssistant = (partial: Partial<ChatMessage>) => {
        setMessages((prev) => {
          const next = [...prev]
          const existing = next[assistantIndex] as ChatMessage | undefined
          next[assistantIndex] = { role: 'assistant', content: '', ...existing, ...partial }
          return next
        })
      }

      updateAssistant({ content: '', thinking: '', createdAt: Date.now() })

      // Basic Auth sessions have no email, so fall back to the username.
      const userInfo = session?.user
        ? {
            id: session.user.email || session.user.name || '',
            email: session.user.email ?? '',
            name: session.user.name ?? '',
          }
        : null
      const payload = {
        text,
        task_type: taskType,
        ...(currentSessionId ? { session_id: currentSessionId } : {}),
        // Include user info so backend can attach it to Portkey metadata.
        ...(userInfo ? { user_info: userInfo } : {}),
      }

      // A proactive refresh (lib/auth.ts's jwt() callback, run on an
      // interval by the SessionProvider) should normally keep the token
      // fresh, but an in-flight request can still race an expiry (device
      // sleep, clock skew). On the first auth failure, force a session
      // refresh and retry once before giving up and signing the user out.
      const runTransport = async (token: string, isRetry: boolean): Promise<void> => {
        const callbacks = {
          onThinking: (chunk: string) => {
            thinking += chunk
            updateAssistant({ thinking })
          },
          onContent: (chunk: string) => {
            content += chunk
            updateAssistant({ content })
          },
          onTraceId: (id: string) => {
            traceId = id
          },
          onRoutingInfo: (info: string) => {
            routingInfo = info
            updateAssistant({ routingInfo: info })
          },
          onDone: (sid: string) => {
            if (sid) {
              sessionIdRef.current = sid
              setSessionId(sid)
            }
            updateAssistant({ content, thinking, traceId, routingInfo, userInfo })
            setIsStreaming(false)
          },
          onError: async (msg: string) => {
            if (!isRetry && isAuthError(msg)) {
              const updated = await update().catch(() => null)
              const refreshed = updated as Record<string, unknown> | null
              const accessToken = refreshed?.accessToken as string | undefined
              if (accessToken && !refreshed?.error) {
                const authMethod = refreshed?.authMethod as string | undefined
                const freshToken = authMethod === 'basic' ? accessToken : `Bearer ${accessToken}`
                tokenCacheRef.current = freshToken
                await runTransport(freshToken, true)
                return
              }
              await signOut({ callbackUrl: '/auth/signin' })
              return
            }
            updateAssistant({ content: `Error: ${msg}`, thinking })
            setIsStreaming(false)
          },
        }

        if (protocol === 'websocket') {
          await sendWS(token, payload, callbacks)
        } else if (protocol === 'sse') {
          await sendSSE(token, payload, callbacks)
        } else {
          await sendREST(token, payload, callbacks)
        }
      }

      try {
        const token = await getToken()
        await runTransport(token, false)
      } catch (err) {
        updateAssistant({ content: `Error: ${String(err)}` })
        setIsStreaming(false)
      }
      return attachments
    },
    // Remove sessionId from deps — we read it from sessionIdRef instead.
    // This means sendMessage is stable and never stale on sessionId changes.
    [
      isStreaming,
      messages.length,
      protocol,
      taskType,
      getToken,
      ensureSessionId,
      uploadFile,
      sendWS,
      sendSSE,
      sendREST,
      update,
    ],
  )

  const resetSession = useCallback(() => {
    setMessages([])
    setSessionId(null)
    sessionIdRef.current = null
    setIsStreaming(false)
  }, [])

  return { sendMessage, messages, isStreaming, sessionId, resetSession, getToken }
}
