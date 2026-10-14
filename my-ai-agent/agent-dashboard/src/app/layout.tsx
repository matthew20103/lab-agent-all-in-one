import type { Metadata } from 'next'
import './globals.css'
import { ThemeProvider, THEME_INIT_SCRIPT } from '@/components/ThemeProvider'

export const metadata: Metadata = {
  title: 'Agent Dashboard',
  description: 'AI Agent All in One',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_INIT_SCRIPT }} />
      </head>
      <body className="font-sans antialiased">
        <ThemeProvider>{children}</ThemeProvider>
      </body>
    </html>
  )
}
