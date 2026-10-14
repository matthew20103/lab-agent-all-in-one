'use client'

import dynamic from 'next/dynamic'
import { useEffect, useRef, useState } from 'react'
import { ChevronDown } from 'lucide-react'

const MarkdownWithGfm = dynamic(
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
        <ReactMarkdown remarkPlugins={[remarkGfm, remarkMath]} rehypePlugins={[rehypeKatex]}>
          {children}
        </ReactMarkdown>
      )
    }
  },
  { ssr: false },
)

interface Props {
  content: string
  isStreaming: boolean
}

export function ThinkingBlock({ content, isStreaming }: Props) {
  const [open, setOpen] = useState(true)
  const prevStreaming = useRef(isStreaming)

  useEffect(() => {
    if (prevStreaming.current && !isStreaming) setOpen(false)
    prevStreaming.current = isStreaming
  }, [isStreaming])

  if (!content) return null

  return (
    <div className="mb-3 border border-border rounded-md overflow-hidden text-sm">
      <button
        onClick={() => setOpen((v) => !v)}
        className="w-full flex items-center justify-between px-3 py-2 bg-muted hover:bg-muted/80 transition-colors text-left"
      >
        <span className="text-xs font-medium text-muted-foreground">Pipeline</span>
        <ChevronDown
          className={`w-3.5 h-3.5 text-muted-foreground transition-transform ${open ? '' : '-rotate-90'}`}
        />
      </button>
      {open && (
        <div className="px-3 py-2 prose prose-sm dark:prose-invert max-w-none">
          <MarkdownWithGfm>{content}</MarkdownWithGfm>
        </div>
      )}
    </div>
  )
}
