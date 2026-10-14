'use client'

import { signOut } from 'next-auth/react'
import { LogOut } from 'lucide-react'
import { initialsOf } from '@/lib/initials'

interface Props {
  name?: string | null
  email?: string | null
}

export function UserMenu({ name, email }: Props) {
  return (
    <div className="flex items-center gap-2.5 rounded-lg border border-border bg-background/70 px-3 py-2">
      <div className="w-8 h-8 rounded-full bg-primary text-primary-foreground flex items-center justify-center shrink-0 text-xs font-semibold">
        {initialsOf(name, email)}
      </div>
      <div className="flex-1 min-w-0">
        {name && <p className="text-xs font-medium truncate">{name}</p>}
        {email && <p className="text-xs text-muted-foreground truncate">{email}</p>}
      </div>
      <button
        onClick={() => signOut({ callbackUrl: '/auth/signin' })}
        className="shrink-0 p-1.5 rounded-md hover:bg-accent transition-colors text-muted-foreground hover:text-foreground"
        title="Sign out"
        aria-label="Sign out"
      >
        <LogOut className="w-3.5 h-3.5" />
      </button>
    </div>
  )
}
