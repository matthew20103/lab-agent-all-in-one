'use client'

import { FileCheck, FileX, Plus, X } from 'lucide-react'
import { BrandLogo } from './BrandLogo'
import { ThemeToggle } from './ThemeToggle'
import { UserMenu } from './UserMenu'
import type { TaskType } from '@/lib/types'
import type { UploadedFile } from './ChatPane'

interface Props {
  onNewSession: () => void
  uploadedFiles?: UploadedFile[]
  taskType: TaskType
  onTaskTypeChange: (v: TaskType) => void
  user?: { name?: string | null; email?: string | null }
  // Shown on mobile, where the sidebar is a drawer
  onClose?: () => void
}

const TASK_TYPES: { value: TaskType; label: string }[] = [
  { value: 'writing', label: 'Writing' },
  { value: 'coding', label: 'Coding' },
]

const sectionLabel = 'text-xs font-semibold text-muted-foreground uppercase tracking-wide block mb-2'

export function Sidebar({ onNewSession, uploadedFiles = [], taskType, onTaskTypeChange, user, onClose }: Props) {
  return (
    <div className="flex h-full flex-col bg-sidebar p-5">
      <header className="mb-6">
        <div className="flex items-start justify-between gap-2">
          <BrandLogo className="h-7" />
          {onClose && (
            <button
              type="button"
              onClick={onClose}
              aria-label="Close sidebar"
              className="md:hidden -mr-1 p-1.5 rounded-md text-muted-foreground hover:text-foreground hover:bg-background/60"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>
        <h1 className="mt-4 text-xl font-bold tracking-tight">AI Agent Workspace</h1>
        <p className="mt-0.5 text-sm text-muted-foreground">AI Agent All in One</p>
      </header>

      <div className="flex-1 overflow-y-auto space-y-6 -mx-1 px-1">
        <section>
          <span className={sectionLabel}>Task Type</span>
          <div className="flex rounded-full border border-border bg-background/70 p-1 text-sm">
            {TASK_TYPES.map(({ value, label }) => (
              <button
                key={value}
                type="button"
                onClick={() => onTaskTypeChange(value)}
                className={`flex-1 rounded-full px-3 py-1.5 transition-colors ${
                  taskType === value
                    ? 'bg-primary text-primary-foreground shadow-sm'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {label}
              </button>
            ))}
          </div>
          <p className="text-xs text-muted-foreground mt-2">Routes your message to the right model via Portkey.</p>
        </section>

        <section>
          <span className={sectionLabel}>Context Files</span>
          {uploadedFiles.length === 0 ? (
            <p className="text-xs text-muted-foreground">Drop files on the chat, or use Attach in the message bar.</p>
          ) : (
            <ul className="space-y-1.5">
              {uploadedFiles.map((f, i) => (
                <li
                  key={i}
                  className="flex items-center gap-2 rounded-lg border border-border bg-background px-3 py-2 text-xs shadow-sm"
                >
                  {f.status === 'ok' ? (
                    <FileCheck className="w-3.5 h-3.5 shrink-0 text-green-600 dark:text-green-400" />
                  ) : (
                    <FileX className="w-3.5 h-3.5 shrink-0 text-destructive" />
                  )}
                  <span className={`truncate ${f.status === 'error' ? 'text-destructive' : ''}`} title={f.name}>
                    {f.name}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <footer className="mt-4 space-y-3">
        {user && <UserMenu name={user.name} email={user.email} />}
        <div className="flex items-center gap-2">
          <ThemeToggle />
          <button
            type="button"
            onClick={onNewSession}
            className="ml-auto flex items-center gap-1.5 rounded-lg border border-primary/40 bg-background px-3 py-2 text-sm font-medium text-primary hover:bg-primary hover:text-primary-foreground transition-colors"
          >
            <Plus className="w-4 h-4" />
            New Session
          </button>
        </div>
      </footer>
    </div>
  )
}
