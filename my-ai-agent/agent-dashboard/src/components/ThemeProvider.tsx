'use client'

import { createContext, useCallback, useContext, useEffect, useState } from 'react'

export type ThemeMode = 'light' | 'dark' | 'system'

const STORAGE_KEY = 'theme'

// Runs in <head> before first paint so a saved dark theme never flashes light.
// Must match the dark/light decision in ThemeProvider's apply() below.
export const THEME_INIT_SCRIPT = `(function(){try{var t=localStorage.getItem('${STORAGE_KEY}');var d=t==='dark'||(t!=='light'&&matchMedia('(prefers-color-scheme: dark)').matches);document.documentElement.classList.toggle('dark',d)}catch(e){}})()`

interface ThemeContextValue {
  // null until the saved choice has been read on the client
  mode: ThemeMode | null
  setMode: (mode: ThemeMode) => void
}

const ThemeContext = createContext<ThemeContextValue>({ mode: null, setMode: () => {} })

export const useTheme = () => useContext(ThemeContext)

function readStoredMode(): ThemeMode {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    return v === 'light' || v === 'dark' ? v : 'system'
  } catch {
    return 'system'
  }
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode | null>(null)

  useEffect(() => {
    setModeState(readStoredMode())
  }, [])

  // Skipped while mode is null: the init script has already applied the right class.
  useEffect(() => {
    if (!mode) return
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const apply = () =>
      document.documentElement.classList.toggle('dark', mode === 'dark' || (mode === 'system' && mq.matches))
    apply()
    if (mode !== 'system') return
    mq.addEventListener('change', apply)
    return () => mq.removeEventListener('change', apply)
  }, [mode])

  const setMode = useCallback((next: ThemeMode) => {
    try {
      if (next === 'system') localStorage.removeItem(STORAGE_KEY)
      else localStorage.setItem(STORAGE_KEY, next)
    } catch {
      // Storage blocked (private mode): the choice still applies for this page view.
    }
    setModeState(next)
  }, [])

  return <ThemeContext.Provider value={{ mode, setMode }}>{children}</ThemeContext.Provider>
}
