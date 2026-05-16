# frozen_string_literal: true

module System
  class RedisJobLock
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
