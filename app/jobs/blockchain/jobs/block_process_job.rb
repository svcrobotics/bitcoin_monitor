# frozen_string_literal: true

module Blockchain
  module Jobs
    class BlockProcessJob
      include Sidekiq::Job

      sidekiq_options queue: :process, retry: 5

      OUTPUTS_BUFFER_KEY = "blockchain:outputs:buffer"
      SPENT_BUFFER_KEY = "blockchain:spent_outputs:buffer"

      def perform(block_height)
        Rails.logger.info("[block_process_job] start height=#{block_height}")

        if redis_backpressure?
          Rails.logger.warn(
            "[block_process_job] backpressure height=#{block_height} reason=redis_buffers_too_high"
          )

          self.class.perform_in(30, block_height)
          return
        end

        block = find_block!(block_height)
        result = Blockchain::Processing::BlockProcessor.new.call(block)

        if result[:skipped]
          Rails.logger.info(
            "[block_process_job] skipped height=#{block_height} reason=#{result[:reason]}"
          )
          return
        end

        if result[:ok]
          Blockchain::Jobs::SpentOutputResolveJob.perform_async(block_height)

          Rails.logger.info(
            "[block_process_job] spent_output_resolve_enqueued height=#{block_height}"
          )
        end

        Rails.logger.info(
          "[block_process_job] done height=#{block_height} " \
          "txs=#{result[:txs].to_i} errors=#{result[:errors].to_i}"
        )
      rescue StandardError => e
        Rails.logger.error(
          "[block_process_job] error height=#{block_height} #{e.class}: #{e.message}"
        )
        raise
      end

      private

      def find_block!(height)
        BlockBufferModel.find_by!(height: height)
      end

      def redis_backpressure?
        outputs_buffer_size > outputs_buffer_limit || spent_buffer_size > spent_buffer_limit
      end

      def outputs_buffer_size
        redis.llen(OUTPUTS_BUFFER_KEY)
      end

      def spent_buffer_size
        redis.llen(SPENT_BUFFER_KEY)
      end

      def outputs_buffer_limit
        ENV.fetch("LAYER1_OUTPUTS_BUFFER_LIMIT", "200000").to_i
      end

      def spent_buffer_limit
        ENV.fetch("LAYER1_SPENT_BUFFER_LIMIT", "50000").to_i
      end

      def redis
        @redis ||= ::Redis.new(
          url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
        )
      end
    end
  end
end