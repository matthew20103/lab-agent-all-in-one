'use client'

import { Monitor, Moon, Sun } from 'lucide-react'
import { useTheme, type ThemeMode } from './ThemeProvider'

const NEXT_MODE: Record<ThemeMode, ThemeMode> = { system: 'light', light: 'dark', dark: 'system' }

const MODE_META: Record<ThemeMode, { Icon: typeof Sun; label: string }> = {
  system: { Icon: Monitor, label: 'System theme' },
  light: { Icon: Sun, label: 'Light theme' },
  dark: { Icon: Moon, label: 'Dark theme' },
}

export function ThemeToggle() {
  const { mode, setMode } = useTheme()
  const { Icon, label } = MODE_META[mode ?? 'system']
  return (
    <button
      type="button"
      onClick={() => mode && setMode(NEXT_MODE[mode])}
      title={`${label} (click to switch)`}
      aria-label={`${label}, click to switch`}
      className="p-2 rounded-lg border border-border bg-background hover:bg-accent text-muted-foreground hover:text-foreground transition-colors"
    >
      <Icon className="w-4 h-4" />
    </button>
  )
}
