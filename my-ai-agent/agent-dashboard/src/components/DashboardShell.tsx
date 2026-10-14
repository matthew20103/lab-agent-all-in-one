'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { Sidebar } from './Sidebar'
import { FileText, Users, Plug, Bot } from 'lucide-react'

const tabs = [
  { href: '/dashboard/instructions', label: 'System Instructions', icon: FileText },
  { href: '/dashboard/mcp-servers', label: 'MCP Servers', icon: Plug },
  { href: '/dashboard/agents', label: 'Sub-agents', icon: Bot },
  { href: '/dashboard/sessions', label: 'Live Sessions', icon: Users },
]

export function DashboardShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname()

  return (
    <div className="flex h-dvh w-full overflow-hidden bg-background">
      <Sidebar />
      <div className="flex flex-1 min-w-0 flex-col overflow-hidden">
        <header className="flex items-center border-b border-border px-6 py-3">
          <nav className="flex flex-wrap gap-1 rounded-full border border-border bg-muted p-1">
            {tabs.map(({ href, label, icon: Icon }) => (
              <Link
                key={href}
                href={href}
                className={`flex items-center gap-2 rounded-full px-4 py-1.5 text-sm transition-colors ${
                  pathname === href
                    ? 'bg-background text-primary font-medium shadow-sm'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                <Icon className="w-4 h-4" />
                {label}
              </Link>
            ))}
          </nav>
        </header>
        <main className="flex-1 overflow-y-auto p-6 lg:p-8">{children}</main>
      </div>
    </div>
  )
}
