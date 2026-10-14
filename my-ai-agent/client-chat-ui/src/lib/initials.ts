export function initialsOf(name?: string | null, email?: string | null): string {
  const source = (name || email || '').trim()
  if (!source) return '?'
  const words = source.split(/[\s@._-]+/).filter(Boolean)
  const letters = words.length > 1 ? words[0][0] + words[1][0] : source.slice(0, 2)
  return letters.toUpperCase()
}
