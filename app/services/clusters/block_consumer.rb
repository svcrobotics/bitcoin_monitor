# frozen_string_literal: true

module Clusters
  class BlockConsumer
    STREAM = ENV.fetch("CLUSTER_BLOCK_STREAM", "bitcoin:blocks")
    PENDING_KEY = ENV.fetch("CLUSTER_PENDING_BLOCKS_KEY", "cluster:pending_blocks")

    def self.call(redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
      new(redis: redis).call
    end

    def initialize(redis:)
      @redis = redis
    end

    def call
      last_id = @redis.get("cluster:block_consumer:last_id") || "0-0"

      entries = @redis.xread(STREAM, last_id, count: 100, block: 1000)
      return 0 if entries.blank?

      processed = 0

      entries.each do |_stream, messages|
        messages.each do |id, data|
          height = data["height"].to_i
          next if height <= 0

          @redis.sadd(PENDING_KEY, height)
          @redis.set("cluster:block_consumer:last_id", id)
          processed += 1
        end
      end

      processed
    end
  end
end

