# frozen_string_literal: true

module Layer1
  class DrainJob < ApplicationJob
    queue_as :layer1_drain

    LOCK_KEY = "layer1:drain:lock"
    MAX_SECONDS = ENV.fetch("LAYER1_DRAIN_MAX_SECONDS", 25).to_i

    def perform
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      locked = redis.set(LOCK_KEY, "1", nx: true, ex: MAX_SECONDS + 30)
      return unless locked

      started_at = Time.current
      total_outputs = 0
      total_spent = 0

      begin
        loop do
          break if Time.current - started_at > MAX_SECONDS

          output_result = Blockchain::Flushers::OutputFlusher.new(redis: redis).call
          total_outputs += output_result[:flushed].to_i

          spent_result = Blockchain::Flushers::SpentOutputFlusher.new(redis: redis).call
          total_spent += spent_result[:flushed].to_i if spent_result.is_a?(Hash)

          break if output_result[:flushed].to_i.zero? && total_spent.zero?
        end

        Rails.logger.info(
          "[layer1_drain] outputs=#{total_outputs} spent=#{total_spent} duration=#{(Time.current - started_at).round(2)}s"
        )
      ensure
        redis.del(LOCK_KEY)
      end
    end
  end
end
