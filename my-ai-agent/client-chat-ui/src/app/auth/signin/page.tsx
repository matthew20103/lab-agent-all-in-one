'use client'

export const dynamic = 'force-dynamic'

import { useState } from 'react'
import { signIn } from 'next-auth/react'
import { BrandLogo } from '@/components/BrandLogo'

export default function SignInPage() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  const handleBasicAuthSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    const result = await signIn('credentials', { username, password, callbackUrl: '/', redirect: false })
    if (result?.error) {
      setError('Sign in failed. Please check your username and password.')
    } else if (result?.ok) {
      window.location.href = '/'
    }
  }

  return (
    <div className="min-h-dvh flex items-center justify-center bg-shell px-4">
      <div className="w-full max-w-sm space-y-6 p-8 border border-border rounded-window bg-card shadow-[0_20px_50px_-12px_rgba(0,0,0,0.18)]">
        <div className="text-center">
          <div className="flex justify-center">
            <BrandLogo className="h-10" />
          </div>
          <h1 className="mt-6 text-xl font-bold tracking-tight">AI Agent Workspace</h1>
          <p className="mt-0.5 text-sm font-medium text-primary">AI Agent All in One</p>
          <p className="mt-3 text-sm text-muted-foreground">Sign in to continue</p>
        </div>

        <button
          onClick={() => signIn('cyberark', { callbackUrl: '/' }, { prompt: 'login' })}
          className="w-full bg-primary text-primary-foreground rounded-lg py-2.5 text-sm font-medium hover:bg-primary/90 transition-colors"
        >
          Sign in with Idira
        </button>

        <div className="flex items-center gap-2">
          <div className="flex-1 h-px bg-border" />
          <span className="text-xs text-muted-foreground">or</span>
          <div className="flex-1 h-px bg-border" />
        </div>

        <form onSubmit={handleBasicAuthSubmit} className="space-y-3">
          <input
            type="text"
            placeholder="Username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            className="w-full rounded-lg border border-input bg-background px-3 py-2.5 text-base md:text-sm focus:border-transparent focus:outline-none focus:ring-2 focus:ring-ring"
            autoComplete="username"
          />
          <input
            type="password"
            placeholder="Password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full rounded-lg border border-input bg-background px-3 py-2.5 text-base md:text-sm focus:border-transparent focus:outline-none focus:ring-2 focus:ring-ring"
            autoComplete="current-password"
          />
          {error && <p className="text-xs text-destructive">{error}</p>}
          <button
            type="submit"
            className="w-full bg-secondary text-secondary-foreground rounded-lg py-2.5 text-sm font-medium hover:bg-secondary/90 transition-colors"
          >
            Sign in with Username & Password
          </button>
        </form>
      </div>
    </div>
  )
}
