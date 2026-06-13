# frozen_string_literal: true

module System
  class RedisJobLock
    def self.with_lock(key, ttl:)
      lock = new(key: "lock:#{key}", ttl: ttl)
      return false unless lock.acquire

      yield
    ensure
      lock&.release
    end

    def initialize(key:, ttl:)
      @key = key
      @ttl = ttl.to_i
      @redis = Sidekiq.redis { |conn| conn }
    end

    def acquire
      @redis.set(
        @key,
        Time.current.to_i,
        nx: true,
        ex: @ttl
      )
    end

    def release
      @redis.del(@key)
    end
  end
end