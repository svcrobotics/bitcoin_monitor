# frozen_string_literal: true

module Realtime
  class BlockStreamConsumerJob < ApplicationJob
    queue_as :realtime

    LOCK_KEY = "lock:block_stream_consumer"
    LOCK_TTL = 5.minutes.to_i

    def perform
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      locked = redis.set(
        LOCK_KEY,
        "#{Process.pid}:#{Time.current.to_i}",
        nx: true,
        ex: LOCK_TTL
      )

      unless locked
        Rails.logger.info("[block_stream_consumer] skip already_running")
        return { ok: true, skipped: true }
      end

      Realtime::BlockStreamConsumer.call(count: Integer(ENV.fetch("BLOCK_STREAM_COUNT", "10")))
    ensure
      redis&.del(LOCK_KEY)
    end
  end
end
