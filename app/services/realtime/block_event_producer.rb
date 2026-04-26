# frozen_string_literal: true

module Realtime
  class BlockEventProducer
    STREAM = "bitcoin.blocks"

    def self.call(height:, blockhash:)
      redis.xadd(
        STREAM,
        {
          type: "new_block",
          height: height.to_i,
          blockhash: blockhash.to_s,
          created_at: Time.current.to_i
        }
      )
    end

    def self.redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    end
  end
end
