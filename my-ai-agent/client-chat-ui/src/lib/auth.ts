import NextAuth, { type NextAuthConfig } from 'next-auth'
import Credentials from 'next-auth/providers/credentials'

// Refresh a bit before the access token actually expires so proactive
// refreshes (via the SessionProvider's refetchInterval) win the race
// against a token expiring mid-request.
const REFRESH_BUFFER_MS = 5 * 60 * 1000

// Cached lazily from the OIDC discovery document so we don't hardcode
// (and have to keep in sync with) Idira's token endpoint URL.
let cachedTokenEndpoint: string | null = null

async function getTokenEndpoint(): Promise<string> {
  if (cachedTokenEndpoint) return cachedTokenEndpoint
  const resp = await fetch(`${process.env.CYBERARK_ISSUER}/.well-known/openid-configuration`)
  if (!resp.ok) throw new Error('Failed to fetch OIDC discovery document')
  const discovery = (await resp.json()) as { token_endpoint: string }
  cachedTokenEndpoint = discovery.token_endpoint
  return cachedTokenEndpoint
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function refreshAccessToken(token: any) {
  try {
    const tokenEndpoint = await getTokenEndpoint()
    const resp = await fetch(tokenEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: token.refreshToken,
        client_id: process.env.CYBERARK_USER_CLIENT_ID ?? '',
        client_secret: process.env.CYBERARK_USER_CLIENT_SECRET ?? '',
      }),
    })
    const refreshed = await resp.json()
    if (!resp.ok) throw refreshed

    return {
      ...token,
      accessToken: refreshed.access_token,
      accessTokenExpires: Date.now() + refreshed.expires_in * 1000,
      // Idira may or may not rotate the refresh token depending on its
      // "Refresh token behavior" setting — always take whatever comes
      // back, falling back to the existing one if it's omitted.
      refreshToken: refreshed.refresh_token ?? token.refreshToken,
      error: undefined,
    }
  } catch (err) {
    console.error('Failed to refresh access token', err)
    return { ...token, error: 'RefreshAccessTokenError' }
  }
}

const authConfig: NextAuthConfig = {
  trustHost: true,
  // Off by default — NextAuth's debug logger is the only place that prints the
  // real `cause` behind an OAuthCallbackError (state mismatch vs. an error=
  // param the IdP itself sent back); the default error() logger drops it.
  // Toggle via AUTH_DEBUG=true in .env + restart, no rebuild needed.
  debug: process.env.AUTH_DEBUG === 'true',
  session: {
    // Match Idira's refresh-token absolute lifetime (365 days) so NextAuth's
    // own session cookie isn't the thing cutting sessions short.
    maxAge: 60 * 60 * 24 * 365,
  },
  providers: [
    {
      id: 'cyberark',
      name: 'Idira',
      type: 'oidc',
      issuer: process.env.CYBERARK_ISSUER,
      clientId: process.env.CYBERARK_USER_CLIENT_ID,
      clientSecret: process.env.CYBERARK_USER_CLIENT_SECRET,
      // Idira doesn't recognize "offline_access" as a scope (rejects the whole
      // authorization request with invalid_scope if requested) — its refresh
      // tokens are issued based on the app's "Issue refresh tokens" console
      // toggle alone, not a requested scope.
      authorization: { params: { scope: 'openid email profile' } },
    },
    Credentials({
      credentials: {
        username: { label: 'Username', type: 'text' },
        password: { label: 'Password', type: 'password' },
      },
      // Checked against the agent backend's BASIC_AUTH_USERS at login time, so a bad
      // username/password is rejected here instead of only failing on the first chat call.
      async authorize(credentials) {
        const username = credentials?.username as string | undefined
        const password = credentials?.password as string | undefined
        if (!username || !password) return null

        const basicAuthHeader = `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`
        const resp = await fetch(`https://${process.env.NEXT_PUBLIC_AGENT_BASE_URL}/api/v1/auth/basic/verify`, {
          method: 'POST',
          headers: { Authorization: basicAuthHeader },
        })
        if (!resp.ok) return null

        return { id: username, name: username, email: '', basicAuthUsername: username, basicAuthPassword: password }
      },
    }),
  ],
  pages: {
    signIn: '/auth/signin',
  },
  callbacks: {
    authorized({ auth, request }) {
      const { pathname } = request.nextUrl
      if (pathname.startsWith('/api')) return true
      return !!auth?.user
    },
    async jwt({ token, account, user }) {
      // Store the CyberArk Identity (Idira) access token on first sign-in
      if (account?.access_token) {
        token.accessToken = account.access_token
        token.accessTokenExpires = account.expires_at ? account.expires_at * 1000 : 0
        token.refreshToken = account.refresh_token
        token.authMethod = 'cyberark'
      }
      // Store the Basic Auth header value on first sign-in via Credentials
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const basicUser = user as any
      if (basicUser?.basicAuthUsername) {
        token.accessToken = `Basic ${Buffer.from(`${basicUser.basicAuthUsername}:${basicUser.basicAuthPassword}`).toString('base64')}`
        token.authMethod = 'basic'
        token.name = basicUser.basicAuthUsername
      }

      // Basic Auth tokens never expire; only Idira access tokens need refreshing.
      if (token.authMethod !== 'cyberark') return token
      if (typeof token.accessTokenExpires !== 'number' || Date.now() < token.accessTokenExpires - REFRESH_BUFFER_MS) {
        return token
      }
      if (!token.refreshToken) return { ...token, error: 'RefreshAccessTokenError' }
      return refreshAccessToken(token)
    },
    async session({ session, token }) {
      if (token?.name) session.user.name = token.name as string
      if (token?.email) session.user.email = token.email as string
      // Expose access token to client so it can call the backend
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(session as any).accessToken = token.accessToken
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(session as any).authMethod = token.authMethod
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(session as any).error = token.error
      return session
    },
  },
}

export const { handlers, auth, signIn, signOut } = NextAuth(authConfig)
