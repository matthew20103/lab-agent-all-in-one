'use client'

import { useState } from 'react'
import { Star } from 'lucide-react'
import { AGENT_FEEDBACK_URL } from '@/lib/constants'
import type { ChatMessage } from '@/lib/types'

interface Props {
  message: ChatMessage
  onUpdate: (updated: Partial<ChatMessage>) => void
}

export function FeedbackWidget({ message, onUpdate }: Props) {
  const [submitting, setSubmitting] = useState(false)
  const [hovered, setHovered] = useState(0)
  const [localRating, setLocalRating] = useState<number>(message.lastFbValue ?? 0)

  if (!message.traceId) return null

  // Once rated, lock — prevents creating duplicate Portkey feedback entries
  const rated = localRating > 0

  const handleRate = async (star: number) => {
    if (submitting || rated) return   // locked after first submission
    setSubmitting(true)
    setLocalRating(star)
    try {
      const resp = await fetch(AGENT_FEEDBACK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          trace_id: message.traceId,
          value: star,
          ...(message.userInfo ? { user_info: message.userInfo } : {}),
        }),
      })
      const data = await resp.json()
      if (data.status === 'success') {
        const newId = data?.data?.feedback_id ?? data?.data?.id
        onUpdate({ feedbackId: newId ?? undefined, lastFbValue: star })
      } else {
        setLocalRating(0)  // revert on failure
      }
    } catch {
      setLocalRating(0)
    } finally {
      setSubmitting(false)
    }
  }

  const displayStar = rated ? localRating : (hovered || 0)

  return (
    <div
      className={`flex items-center gap-0.5 mt-2 ${rated ? '' : ''}`}
      onMouseLeave={() => !rated && setHovered(0)}
    >
      {[1, 2, 3, 4, 5].map((star) => (
        <button
          key={star}
          disabled={submitting || rated}
          onMouseEnter={() => !rated && setHovered(star)}
          onClick={() => handleRate(star)}
          className={`p-0.5 transition-transform ${
            rated
              ? 'cursor-default'
              : 'hover:scale-110 cursor-pointer'
          } disabled:opacity-100`}
          aria-label={`Rate ${star} star${star > 1 ? 's' : ''}`}
        >
          <Star
            className={`w-4 h-4 transition-colors ${
              star <= displayStar
                ? 'fill-yellow-400 text-yellow-400'
                : rated
                  ? 'text-muted-foreground/30'
                  : 'text-muted-foreground hover:text-yellow-300'
            }`}
          />
        </button>
      ))}
      {rated && (
        <span className="text-xs text-muted-foreground ml-1.5">{localRating}/5</span>
      )}
      {!rated && submitting && (
        <span className="text-xs text-muted-foreground ml-1.5">Saving…</span>
      )}
    </div>
  )
}
