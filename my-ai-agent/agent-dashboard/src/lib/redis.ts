import Redis from 'ioredis'

declare global {
  // eslint-disable-next-line no-var
  var redis: Redis | undefined
}

const redis =
  global.redis ??
  new Redis(process.env.REDIS_URL ?? 'redis://redis:6379', {
    lazyConnect: true,
    maxRetriesPerRequest: 3,
  })

if (process.env.NODE_ENV !== 'production') global.redis = redis

export default redis
