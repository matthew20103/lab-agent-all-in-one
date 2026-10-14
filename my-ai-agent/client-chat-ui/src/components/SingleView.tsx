'use client'

import { useEffect, useRef, useState } from 'react'
import { FileText, Image as ImageIcon, Loader2, Paperclip, Send, Upload, X } from 'lucide-react'
import { ChatPane, type ChatPaneHandle, type UploadedFile } from './ChatPane'
import { ALLOWED_FILE_EXTENSIONS, MAX_FILES_PER_MESSAGE, MAX_UPLOAD_BYTES } from '@/lib/constants'
import type { Protocol, TaskType } from '@/lib/types'

interface Props {
  protocol: Protocol
  connectionLabel?: string
  taskType: TaskType
  onFileUploaded?: (file: UploadedFile) => void
  onOpenSidebar?: () => void
  showFeedback?: boolean
}

const IMAGE_EXTENSIONS = ['.png', '.jpg', '.jpeg']
const MAX_UPLOAD_MB = MAX_UPLOAD_BYTES / 1024 / 1024
// About 8 lines (20px line height + 24px padding) before the textarea scrolls
const MAX_TEXTAREA_PX = 184

function extensionOf(name: string) {
  const i = name.lastIndexOf('.')
  return i >= 0 ? name.slice(i).toLowerCase() : ''
}

function formatSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

// Only react to drags that carry files, so dragging selected text does nothing.
const carriesFiles = (e: { dataTransfer: DataTransfer | null }) =>
  Array.from(e.dataTransfer?.types ?? []).includes('Files')

export function SingleView({
  protocol,
  connectionLabel,
  taskType,
  onFileUploaded,
  onOpenSidebar,
  showFeedback = false,
}: Props) {
  const [input, setInput] = useState('')
  const [pendingFiles, setPendingFiles] = useState<File[]>([])
  const [rejectMessage, setRejectMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [dragging, setDragging] = useState(false)
  const dragDepth = useRef(0)
  const sendingRef = useRef(false)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const ref = useRef<ChatPaneHandle>(null)

  // Grow with the text up to MAX_TEXTAREA_PX, then scroll; shrinks back when cleared.
  useEffect(() => {
    const el = textareaRef.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = `${Math.min(el.scrollHeight, MAX_TEXTAREA_PX)}px`
  }, [input])

  // Enter sends, Shift+Enter is a new line. Ignore Enter while an IME is composing
  // (e.g. Chinese/Japanese input), where it confirms a word rather than sending.
  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key !== 'Enter' || e.shiftKey || e.nativeEvent.isComposing) return
    e.preventDefault()
    handleSend()
  }

  // A file dropped just outside the drop zone would otherwise make the browser
  // navigate to it and lose the conversation.
  useEffect(() => {
    const block = (e: DragEvent) => {
      if (carriesFiles(e)) e.preventDefault()
    }
    window.addEventListener('dragover', block)
    window.addEventListener('drop', block)
    return () => {
      window.removeEventListener('dragover', block)
      window.removeEventListener('drop', block)
    }
  }, [])

  const addFiles = (files: File[]) => {
    const next = [...pendingFiles]
    const rejected: string[] = []
    for (const f of files) {
      if (!ALLOWED_FILE_EXTENSIONS.includes(extensionOf(f.name))) rejected.push(`${f.name} isn't a supported file type`)
      else if (f.size > MAX_UPLOAD_BYTES) rejected.push(`${f.name} is over ${MAX_UPLOAD_MB} MB`)
      else if (next.some((p) => p.name === f.name && p.size === f.size)) continue
      else if (next.length >= MAX_FILES_PER_MESSAGE) rejected.push(`${f.name}: up to ${MAX_FILES_PER_MESSAGE} files per message`)
      else next.push(f)
    }
    setPendingFiles(next)
    setRejectMessage(rejected.length ? rejected.join(' · ') : null)
  }

  const canSend = !busy && (input.trim().length > 0 || pendingFiles.length > 0)

  const handleSend = async () => {
    // The ref blocks a double Enter in the same render, before `busy` has updated.
    if (!canSend || sendingRef.current) return
    sendingRef.current = true
    const text = input.trim()
    const files = pendingFiles
    setInput('')
    setPendingFiles([])
    setRejectMessage(null)
    // On phones, close the keyboard after sending so the reply is read full screen.
    if (window.matchMedia('(hover: none)').matches) textareaRef.current?.blur()
    try {
      await ref.current?.send(text, files)
    } finally {
      sendingRef.current = false
    }
  }

  const onDragEnter = (e: React.DragEvent) => {
    if (!carriesFiles(e)) return
    e.preventDefault()
    dragDepth.current += 1
    setDragging(true)
  }

  const onDragOver = (e: React.DragEvent) => {
    if (!carriesFiles(e)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
  }

  // Entering a child fires dragleave on the parent, so count depth instead of toggling.
  const onDragLeave = (e: React.DragEvent) => {
    if (!carriesFiles(e)) return
    dragDepth.current = Math.max(0, dragDepth.current - 1)
    if (dragDepth.current === 0) setDragging(false)
  }

  const onDrop = (e: React.DragEvent) => {
    if (!carriesFiles(e)) return
    e.preventDefault()
    dragDepth.current = 0
    setDragging(false)
    addFiles(Array.from(e.dataTransfer.files))
  }

  return (
    <div
      className="relative flex flex-col h-full"
      onDragEnter={onDragEnter}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
      <div className="flex-1 overflow-hidden">
        <ChatPane
          ref={ref}
          protocol={protocol}
          taskType={taskType}
          connectionLabel={connectionLabel}
          onFileUploaded={onFileUploaded}
          onBusyChange={setBusy}
          onOpenSidebar={onOpenSidebar}
          showFeedback={showFeedback}
        />
      </div>
      <div className="border-t border-border px-4 pb-4 pt-3">
        <div className="mx-auto max-w-3xl">
          {/* Action chips: icon only until hovered, then the label slides out (NextChat style) */}
          <div className="mb-2 flex items-center gap-2">
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              aria-label="Attach files"
              className="group/chip flex items-center rounded-full border border-border bg-background px-2.5 py-1.5 text-xs text-muted-foreground hover:border-primary/50 hover:text-primary focus-visible:text-primary transition-colors"
            >
              <Paperclip className="w-3.5 h-3.5" />
              <span className="max-w-0 overflow-hidden whitespace-nowrap transition-all duration-200 group-hover/chip:ml-1 group-hover/chip:max-w-[5rem] group-focus-visible/chip:ml-1 group-focus-visible/chip:max-w-[5rem]">
                Attach
              </span>
            </button>
            <input
              ref={fileInputRef}
              type="file"
              multiple
              accept={ALLOWED_FILE_EXTENSIONS.join(',')}
              className="hidden"
              onChange={(e) => {
                addFiles(Array.from(e.target.files ?? []))
                e.target.value = ''
              }}
            />
          </div>
          {pendingFiles.length > 0 && (
            <ul className="flex flex-wrap gap-2 mb-2">
              {pendingFiles.map((f) => {
                const Icon = IMAGE_EXTENSIONS.includes(extensionOf(f.name)) ? ImageIcon : FileText
                return (
                  <li
                    key={`${f.name}-${f.size}`}
                    className="flex items-center gap-1.5 max-w-[16rem] bg-muted rounded-lg pl-2.5 pr-1 py-1 text-xs"
                  >
                    <Icon className="w-3.5 h-3.5 shrink-0 text-muted-foreground" />
                    <span className="truncate" title={f.name}>
                      {f.name}
                    </span>
                    <span className="shrink-0 text-muted-foreground">{formatSize(f.size)}</span>
                    <button
                      type="button"
                      onClick={() => setPendingFiles(pendingFiles.filter((p) => p !== f))}
                      aria-label={`Remove ${f.name}`}
                      className="p-0.5 rounded hover:bg-background transition-colors"
                    >
                      <X className="w-3 h-3" />
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
          <div className="relative">
            {/* 16px text below md: iOS Safari zooms into inputs under 16px on focus and stays zoomed */}
            <textarea
              ref={textareaRef}
              rows={1}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={onKeyDown}
              placeholder="Enter to send, Shift + Enter for a new line, drop files to attach"
              className="block w-full resize-none rounded-[10px] border border-input bg-background py-3 pl-4 pr-28 text-base md:text-sm leading-5 placeholder:text-muted-foreground focus:border-transparent focus:outline-none focus:ring-2 focus:ring-ring"
            />
            <button
              onClick={handleSend}
              disabled={!canSend}
              aria-label="Send"
              className="absolute bottom-2 right-2 flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors disabled:opacity-50"
            >
              {busy ? <Loader2 className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4" />}
              Send
            </button>
          </div>
          {rejectMessage && <p className="text-xs text-destructive mt-2">{rejectMessage}</p>}
        </div>
      </div>

      {dragging && (
        <div className="pointer-events-none absolute inset-2 z-10 flex flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-primary bg-background/80 backdrop-blur-sm">
          <Upload className="w-6 h-6 text-primary" />
          <p className="text-sm font-medium">Drop files to add them to your message</p>
          <p className="text-xs text-muted-foreground">
            PDF, images, Office, text and code files · up to {MAX_UPLOAD_MB} MB each
          </p>
        </div>
      )}
    </div>
  )
}
