# frozen_string_literal: true

module Blockchain
  module Flushers
    class SpentOutputFlusherJob < ApplicationJob
      queue_as :flushers

      REDIS_KEY = "blockchain:spent_outputs:buffer"
      CONTINUE_THRESHOLD = 5_000

      def perform
        result = Blockchain::Flushers::SpentOutputFlusher.new.call

        remaining = ::Redis.new(
          url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
        ).llen(REDIS_KEY)

        Rails.logger.info(
          "[spent_output_flusher_job] flushed=#{result[:flushed].to_i} remaining=#{remaining}"
        )

        self.class.perform_later if remaining > CONTINUE_THRESHOLD
      end
    end
  end
end