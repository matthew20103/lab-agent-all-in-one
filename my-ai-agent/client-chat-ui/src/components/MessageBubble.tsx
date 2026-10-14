'use client'

import { useState } from 'react'
import dynamic from 'next/dynamic'
import { useSession } from 'next-auth/react'
import { AlertTriangle, Bot, Check, CheckCircle2, Copy, Loader2, Paperclip, XCircle } from 'lucide-react'
import { ThinkingBlock } from './ThinkingBlock'
import { FeedbackWidget } from './FeedbackWidget'
import { initialsOf } from '@/lib/initials'
import type { Attachment, ChatMessage } from '@/lib/types'

const ATTACHMENT_STATUS = {
  uploading: { Icon: Loader2, className: 'text-muted-foreground animate-spin', label: 'Uploading…' },
  ok: { Icon: CheckCircle2, className: 'text-emerald-600 dark:text-emerald-400', label: 'Added to the conversation' },
  unsupported: {
    Icon: AlertTriangle,
    className: 'text-amber-600 dark:text-amber-400',
    label: "Uploaded, but the active model can't read images/PDFs",
  },
  error: { Icon: XCircle, className: 'text-destructive', label: 'Upload failed' },
} as const

function AttachmentChip({ attachment }: { attachment: Attachment }) {
  const { Icon, className, label } = ATTACHMENT_STATUS[attachment.status]
  return (
    <li
      title={attachment.error ?? label}
      className="flex items-center gap-1.5 max-w-[16rem] bg-muted border border-border rounded-lg px-2.5 py-1 text-xs"
    >
      <Paperclip className="w-3 h-3 shrink-0 text-muted-foreground" />
      <span className="truncate">{attachment.name}</span>
      <Icon className={`w-3.5 h-3.5 shrink-0 ${className}`} aria-label={attachment.error ?? label} />
    </li>
  )
}

const MarkdownRenderer = dynamic(
  async () => {
    const [
      { default: ReactMarkdown },
      { default: remarkGfm },
      { default: remarkMath },
      { default: rehypeKatex },
    ] = await Promise.all([
      import('react-markdown'),
      import('remark-gfm'),
      import('remark-math'),
      import('rehype-katex'),
    ])

    return function Md({ children }: { children: string }) {
      return (
        <ReactMarkdown
          remarkPlugins={[remarkGfm, remarkMath]}
          rehypePlugins={[rehypeKatex]}
          components={{
            // ── Tables ──────────────────────────────────────────────────────
            table: ({ children }) => (
              <div className="overflow-x-auto my-3 rounded-md border border-border">
                <table className="min-w-full border-collapse text-sm">{children}</table>
              </div>
            ),
            thead: ({ children }) => (
              <thead className="bg-muted/60 border-b border-border">{children}</thead>
            ),
            tbody: ({ children }) => <tbody>{children}</tbody>,
            tr: ({ children }) => (
              <tr className="border-b border-border last:border-0 even:bg-muted/20">{children}</tr>
            ),
            th: ({ children }) => (
              <th className="px-4 py-2 text-left font-semibold text-xs uppercase tracking-wide text-muted-foreground whitespace-nowrap">
                {children}
              </th>
            ),
            td: ({ children }) => (
              <td className="px-4 py-2 align-top text-sm">{children}</td>
            ),
            // ── Code ────────────────────────────────────────────────────────
            code: ({ className, children }) => {
              // A fenced code block with no language info string (```…```,
              // which is exactly what our diagram fencer emits, and what a
              // model produces when it self-fences) gets NO `language-*`
              // className at all — only an explicit ```lang fence does. So
              // className alone can't tell block from inline here. But a
              // genuine inline code span can never contain a literal newline
              // (CommonMark collapses them to a space), so any multi-line
              // content is reliably a block regardless of its className.
              const isBlock = Boolean(className?.startsWith('language-')) || String(children).includes('\n')
              if (isBlock) {
                return (
                  <div className="overflow-x-auto my-3 rounded-lg border border-border">
                    <pre className="bg-[#1e1e2e] dark:bg-[#11111b] text-[#cdd6f4] p-4 text-xs leading-relaxed overflow-x-auto">
                      <code className={className}>{children}</code>
                    </pre>
                  </div>
                )
              }
              return (
                <code className="bg-muted text-foreground px-1.5 py-0.5 rounded text-[0.8em] font-mono">
                  {children}
                </code>
              )
            },
            pre: ({ children }) => <>{children}</>,
            // ── Blockquote ───────────────────────────────────────────────────
            blockquote: ({ children }) => (
              <blockquote className="border-l-4 border-primary/50 bg-muted/30 pl-4 pr-2 py-1 my-3 rounded-r-md italic text-muted-foreground">
                {children}
              </blockquote>
            ),
            // ── Lists ────────────────────────────────────────────────────────
            ul: ({ children }) => (
              <ul className="list-disc list-outside ml-5 space-y-0.5 my-2">{children}</ul>
            ),
            ol: ({ children }) => (
              <ol className="list-decimal list-outside ml-5 space-y-0.5 my-2">{children}</ol>
            ),
            li: ({ children }) => <li className="pl-1">{children}</li>,
            // ── Headings ─────────────────────────────────────────────────────
            h1: ({ children }) => <h1 className="text-xl font-bold mt-5 mb-2 border-b border-border pb-1">{children}</h1>,
            h2: ({ children }) => <h2 className="text-lg font-bold mt-4 mb-1.5">{children}</h2>,
            h3: ({ children }) => <h3 className="text-base font-semibold mt-3 mb-1">{children}</h3>,
            h4: ({ children }) => <h4 className="text-sm font-semibold mt-2 mb-0.5">{children}</h4>,
            // ── Inline ───────────────────────────────────────────────────────
            a: ({ href, children }) => (
              <a href={href} target="_blank" rel="noopener noreferrer"
                className="text-primary underline underline-offset-2 hover:opacity-80 break-all">
                {children}
              </a>
            ),
            strong: ({ children }) => <strong className="font-semibold">{children}</strong>,
            hr: () => <hr className="my-4 border-border" />,
            p: ({ children }) => <p className="my-1.5 leading-relaxed">{children}</p>,
          }}
        >
          {children}
        </ReactMarkdown>
      )
    }
  },
  { ssr: false },
)

interface Props {
  message: ChatMessage
  isStreaming?: boolean
  onUpdate: (updated: Partial<ChatMessage>) => void
  showFeedback?: boolean
}

function formatTime(ts?: number) {
  return ts ? new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : ''
}

// Hidden until the message is hovered (NextChat style); always visible on touch screens.
const hoverActions =
  'opacity-0 group-hover:opacity-100 focus-within:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity'

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // Clipboard blocked (insecure context or denied permission): nothing useful to show.
    }
  }
  return (
    <button
      type="button"
      onClick={copy}
      aria-label={copied ? 'Copied' : 'Copy message'}
      className="flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs text-muted-foreground hover:bg-accent hover:text-foreground transition-colors"
    >
      {copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
      {copied ? 'Copied' : 'Copy'}
    </button>
  )
}

function UserAvatar() {
  const { data: session } = useSession()
  return (
    <div className="w-8 h-8 shrink-0 rounded-full bg-primary text-primary-foreground flex items-center justify-center text-xs font-semibold">
      {initialsOf(session?.user?.name, session?.user?.email)}
    </div>
  )
}

export function MessageBubble({ message, isStreaming = false, onUpdate, showFeedback = false }: Props) {
  const time = formatTime(message.createdAt)

  if (message.role === 'user') {
    return (
      <div className="group mb-6 flex flex-col items-end">
        <div className="mb-1.5 flex items-center gap-2">
          {message.content && (
            <div className={hoverActions}>
              <CopyButton text={message.content} />
            </div>
          )}
          <UserAvatar />
        </div>
        {message.attachments && message.attachments.length > 0 && (
          <ul className="mb-1.5 flex flex-wrap justify-end gap-1.5 max-w-[80%]">
            {message.attachments.map((a, i) => (
              <AttachmentChip key={`${a.name}-${i}`} attachment={a} />
            ))}
          </ul>
        )}
        {message.content && (
          <div className="max-w-[80%] rounded-[10px] bg-bubble-user px-4 py-3 text-sm whitespace-pre-wrap break-words">
            {message.content}
          </div>
        )}
        {time && <span className="mt-1 text-[11px] text-muted-foreground">{time}</span>}
      </div>
    )
  }

  return (
    <div className="group mb-6 flex flex-col items-start">
      <div className="mb-1.5 flex items-center gap-2">
        <div className="w-8 h-8 shrink-0 rounded-lg bg-primary/10 text-primary flex items-center justify-center">
          <Bot className="w-4 h-4" />
        </div>
        {!isStreaming && message.content && (
          <div className={hoverActions}>
            <CopyButton text={message.content} />
          </div>
        )}
      </div>
      <div className="w-full max-w-[92%]">
        {message.thinking && (
          <ThinkingBlock content={message.thinking} isStreaming={isStreaming} />
        )}
        <div className="w-fit max-w-full rounded-[10px] border border-border bg-muted px-4 py-3 text-sm text-foreground leading-relaxed min-h-[1.25rem]">
          <MarkdownRenderer>{message.content || (isStreaming ? '​' : '')}</MarkdownRenderer>
          {isStreaming && message.content && (
            <span className="streaming-cursor inline-block" />
          )}
        </div>
        {message.routingInfo && (
          <div className="mt-2 bg-muted/50 border border-border rounded-md px-3 py-2 text-xs text-muted-foreground">
            <div className="flex items-center gap-1.5 font-semibold text-foreground mb-1">
              🔀 Portkey
            </div>
            {message.routingInfo.split('\n').map((line, i) => (
              <div key={i} className="font-mono leading-relaxed"
                dangerouslySetInnerHTML={{ __html: line
                  .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
                  .replace(/`(.*?)`/g, '<code class="bg-muted px-1 rounded">$1</code>')
                }}
              />
            ))}
          </div>
        )}
        {showFeedback && <FeedbackWidget message={message} onUpdate={onUpdate} />}
        {time && <span className="mt-1 block text-[11px] text-muted-foreground">{time}</span>}
      </div>
    </div>
  )
}
