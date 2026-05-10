# frozen_string_literal: true

module System
  class BlockchainPipelineStatus
    OUTPUT_KEY = "blockchain:outputs:buffer"
    SPENT_OUTPUT_KEY = "blockchain:spent_outputs:buffer"

    def self.call
      new.call
    end

    def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
      @redis = redis
    end

    def call
      {
        outputs_buffer_size: llen(OUTPUT_KEY),
        spent_outputs_buffer_size: llen(SPENT_OUTPUT_KEY),
        total_buffered_rows: total_rows,
        state: pipeline_state
      }
    end

    private

    def llen(key)
      @redis.llen(key)
    end

    def total_rows
      llen(OUTPUT_KEY) + llen(SPENT_OUTPUT_KEY)
    end

    def pipeline_state
      return "critical" if total_rows > 500_000
      return "warning" if total_rows > 50_000

      "ok"
    end
  end
end