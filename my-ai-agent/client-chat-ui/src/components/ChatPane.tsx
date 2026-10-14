'use client'

import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react'
import { Menu } from 'lucide-react'
import { MessageBubble } from './MessageBubble'
import { BrandLogo } from './BrandLogo'
import { useAgentStream } from '@/hooks/useAgentStream'
import type { Protocol, TaskType, ChatMessage } from '@/lib/types'

export interface UploadedFile {
  name: string
  status: 'ok' | 'error'
}

export interface ChatPaneHandle {
  send: (text: string, files: File[]) => Promise<void>
}

interface Props {
  protocol: Protocol
  taskType: TaskType
  // Shown as a badge in the chat header, e.g. "WebSocket"
  connectionLabel?: string
  onFileUploaded?: (file: UploadedFile) => void
  // True from the moment a send starts (uploads included) until its reply is saved.
  onBusyChange?: (busy: boolean) => void
  // Opens the sidebar drawer on mobile
  onOpenSidebar?: () => void
  showFeedback?: boolean
}

export const ChatPane = forwardRef<ChatPaneHandle, Props>(function ChatPane(
  { protocol, taskType, connectionLabel, onFileUploaded, onBusyChange, onOpenSidebar, showFeedback = false },
  ref,
) {
  const { sendMessage, messages, isStreaming } = useAgentStream(protocol, taskType)
  const scrollRef = useRef<HTMLDivElement>(null)
  // Stores feedbackId and lastFbValue per message index — persists across re-renders
  const [feedbackMap, setFeedbackMap] = useState<Record<number, Partial<ChatMessage>>>({})

  // Scroll only the message list. scrollIntoView() would also scroll the page itself,
  // and with the iOS keyboard open that shifts the whole layout up and leaves it there.
  useEffect(() => {
    const el = scrollRef.current
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
  }, [messages])

  useEffect(() => {
    onBusyChange?.(isStreaming)
  }, [isStreaming, onBusyChange])

  const send = useCallback(
    async (text: string, files: File[]) => {
      const results = await sendMessage(text, files)
      for (const r of results) {
        onFileUploaded?.({ name: r.name, status: r.status === 'ok' ? 'ok' : 'error' })
      }
    },
    [sendMessage, onFileUploaded],
  )

  useImperativeHandle(ref, () => ({ send }), [send])

  const handleUpdate = useCallback(
    (index: number, partial: Partial<ChatMessage>) => {
      setFeedbackMap((prev) => ({
        ...prev,
        [index]: { ...prev[index], ...partial },
      }))
    },
    [],
  )

  // NextChat-style header title: the conversation's first user message, or its first file.
  const firstUser = messages.find((m) => m.role === 'user')
  const title = firstUser?.content || firstUser?.attachments?.[0]?.name || 'New conversation'

  return (
    <div className="flex flex-col h-full">
      <header className="flex items-center gap-3 border-b border-border px-5 py-3">
        {onOpenSidebar && (
          <button
            type="button"
            onClick={onOpenSidebar}
            aria-label="Open sidebar"
            className="md:hidden -ml-1.5 p-1.5 rounded-md text-muted-foreground hover:text-foreground hover:bg-accent"
          >
            <Menu className="w-5 h-5" />
          </button>
        )}
        <div className="min-w-0 flex-1">
          <h2 className="truncate text-base font-semibold" title={title}>
            {title}
          </h2>
          <p className="text-xs text-muted-foreground">
            {messages.length} message{messages.length === 1 ? '' : 's'}
          </p>
        </div>
        {connectionLabel && (
          <span
            className="shrink-0 inline-flex items-center gap-1.5 rounded-full border border-border bg-muted px-2.5 py-1 text-xs text-muted-foreground"
            title="Connection method (set in the admin dashboard)"
          >
            <span className="w-1.5 h-1.5 rounded-full bg-primary" />
            {connectionLabel}
          </span>
        )}
      </header>

      <div ref={scrollRef} className="flex-1 overflow-y-auto">
        {messages.length === 0 ? (
          <div className="flex h-full flex-col items-center justify-center px-6 text-center">
            <BrandLogo className="h-12" />
            <h3 className="mt-6 text-2xl font-bold tracking-tight">AI Agent Workspace</h3>
            <p className="mt-1 text-sm font-medium text-primary">AI Agent All in One</p>
            <p className="mt-4 text-sm text-muted-foreground">Send a message or drop a file to start.</p>
          </div>
        ) : (
          <div className="mx-auto max-w-3xl px-4 py-5">
            {messages.map((msg, i) => (
              <MessageBubble
                key={i}
                message={{ ...msg, ...feedbackMap[i] }}
                isStreaming={isStreaming && i === messages.length - 1 && msg.role === 'assistant'}
                onUpdate={(partial) => handleUpdate(i, partial)}
                showFeedback={showFeedback}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
})
