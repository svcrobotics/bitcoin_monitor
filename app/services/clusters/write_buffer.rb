# frozen_string_literal: true

module Clusters
  class WriteBuffer
    STREAM = ENV.fetch("CLUSTER_WRITE_STREAM", "cluster:writes")

    def self.push(event:, payload:, redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
      new(redis: redis).push(event: event, payload: payload)
    end

    def initialize(redis:)
      @redis = redis
    end

    def push(event:, payload:)
      @redis.xadd(
        STREAM,
        {
          event: event,
          payload: payload.to_json,
          created_at: Time.current.iso8601
        },
        maxlen: 10_000,
        approximate: true
      )
    end
  end
end

