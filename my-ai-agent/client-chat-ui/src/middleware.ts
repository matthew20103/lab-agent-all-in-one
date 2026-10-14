export { auth as default } from '@/lib/auth'

export const runtime = 'nodejs'

export const config = {
  // Only protect the UI pages — exclude all API routes and static assets. brand/ must stay
  // public so the logo loads on the sign-in page for signed-out visitors.
  matcher: ['/((?!api|_next/static|_next/image|favicon.ico|brand/).*)'],
}
