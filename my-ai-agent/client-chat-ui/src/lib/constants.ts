export const AGENT_BASE_URL = process.env.NEXT_PUBLIC_AGENT_BASE_URL ?? 'agent.example.com'
export const AGENT_WSS_URL = `wss://${AGENT_BASE_URL}/ws`
export const AGENT_REST_URL = `https://${AGENT_BASE_URL}/api/v1/chat`
export const AGENT_STREAM_URL = `https://${AGENT_BASE_URL}/api/v1/chat/stream`
export const AGENT_UPLOAD_URL = `https://${AGENT_BASE_URL}/api/v1/upload`
export const AGENT_FEEDBACK_URL = `https://${AGENT_BASE_URL}/api/v1/feedback`

export const ALLOWED_FILE_EXTENSIONS = [
  '.csv', '.xlsx', '.xls', '.docx', '.pdf', '.txt', '.md', '.json',
  '.py', '.js', '.ts', '.html', '.css', '.java', '.cpp', '.c', '.cs', '.go', '.rs',
  '.yaml', '.yml', '.sh', '.xml', '.png', '.jpg', '.jpeg',
]

// The backend has no size limit; drag-and-drop makes a huge accidental drop easy.
export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024
export const MAX_FILES_PER_MESSAGE = 10
