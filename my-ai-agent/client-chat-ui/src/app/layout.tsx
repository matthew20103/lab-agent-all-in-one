import type { Metadata } from 'next'
import './globals.css'
import 'katex/dist/katex.min.css'
import { ThemeProvider, THEME_INIT_SCRIPT } from '@/components/ThemeProvider'
import { SessionProvider } from 'next-auth/react'

export const metadata: Metadata = {
  title: 'AI Agent Workspace',
  description: 'AI Agent All in One',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_INIT_SCRIPT }} />
      </head>
      <body className="font-sans antialiased">
        {/* Poll every 5 min so the jwt() refresh check runs even if the tab never loses focus. */}
        <SessionProvider refetchInterval={5 * 60}>
          <ThemeProvider>{children}</ThemeProvider>
        </SessionProvider>
      </body>
    </html>
  )
}
