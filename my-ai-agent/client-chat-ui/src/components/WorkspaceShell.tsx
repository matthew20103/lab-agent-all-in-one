'use client'

import { useCallback, useEffect, useState } from 'react'
import { useSession } from 'next-auth/react'
import { Sidebar } from './Sidebar'
import { SingleView } from './SingleView'
import { AGENT_BASE_URL } from '@/lib/constants'
import type { Protocol, TaskType } from '@/lib/types'
import type { UploadedFile } from './ChatPane'

const PROTOCOL_LABELS: Record<Protocol, string> = {
  websocket: 'WebSocket',
  sse: 'SSE',
  rest: 'REST',
}

export function WorkspaceShell() {
  const { data: session } = useSession()
  const [protocol, setProtocol] = useState<Protocol>('websocket')
  const [sessionKey, setSessionKey] = useState(0)
  const [uploadedFiles, setUploadedFiles] = useState<UploadedFile[]>([])
  const [taskType, setTaskType] = useState<TaskType>('writing')
  // Mobile only: the sidebar is a slide-out drawer below the md breakpoint
  const [sidebarOpen, setSidebarOpen] = useState(false)

  // iOS Safari doesn't shrink the page when the keyboard opens; it slides the page up to
  // show the input, and may not slide it back. Size the app to the visible area instead and
  // undo the slide, like a native chat app. Skipped while pinch-zoomed (scale > 1), so
  // zooming and panning around still work.
  useEffect(() => {
    const vv = window.visualViewport
    if (!vv) return
    const root = document.documentElement
    const sync = () => {
      if (vv.scale > 1.01) return
      root.style.setProperty('--app-height', `${vv.height}px`)
      if (window.scrollY !== 0) window.scrollTo(0, 0)
    }
    sync()
    vv.addEventListener('resize', sync)
    vv.addEventListener('scroll', sync)
    return () => {
      vv.removeEventListener('resize', sync)
      vv.removeEventListener('scroll', sync)
      root.style.removeProperty('--app-height')
    }
  }, [])

  useEffect(() => {
    if (!sidebarOpen) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setSidebarOpen(false)
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [sidebarOpen])

  useEffect(() => {
    const fetchConfig = () => {
      fetch(`https://${AGENT_BASE_URL}/api/v1/client-config`)
        .then((r) => r.json())
        .then((data) => {
          if (data.connection_method) setProtocol(data.connection_method as Protocol)
        })
        .catch(() => {})
    }
    fetchConfig()
    const interval = setInterval(fetchConfig, 15000)
    return () => clearInterval(interval)
  }, [])

  const handleNewSession = () => {
    setSessionKey((k) => k + 1)
    setUploadedFiles([])
    setSidebarOpen(false)
  }

  const handleFileUploaded = useCallback((file: UploadedFile) => {
    setUploadedFiles((prev) => [...prev, file])
  }, [])

  return (
    <div className="relative flex w-full overflow-hidden bg-background" style={{ height: 'var(--app-height, 100dvh)' }}>
      {sidebarOpen && (
        <div className="fixed inset-0 z-30 bg-black/40 md:hidden" onClick={() => setSidebarOpen(false)} aria-hidden />
      )}
      <aside
        className={`fixed inset-y-0 left-0 z-40 w-[300px] max-w-[85vw] shrink-0 border-r border-border transition-transform duration-200 md:static md:z-auto md:translate-x-0 ${
          sidebarOpen ? 'translate-x-0' : '-translate-x-full'
        }`}
      >
        <Sidebar
          onNewSession={handleNewSession}
          uploadedFiles={uploadedFiles}
          taskType={taskType}
          onTaskTypeChange={setTaskType}
          user={session?.user ?? undefined}
          onClose={() => setSidebarOpen(false)}
        />
      </aside>
      <main className="flex-1 min-w-0 overflow-hidden" key={sessionKey}>
        <SingleView
          protocol={protocol}
          connectionLabel={PROTOCOL_LABELS[protocol]}
          taskType={taskType}
          onFileUploaded={handleFileUploaded}
          onOpenSidebar={() => setSidebarOpen(true)}
          showFeedback={true}
        />
      </main>
    </div>
  )
}
