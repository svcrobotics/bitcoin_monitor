# frozen_string_literal: true

module Blockchain
  module State
    class ProcessingRunner
      DEFAULT_BATCH = 10
      ENV_KEY = "LAYER1_PROCESSING_BATCH_SIZE"

      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def call(limit: nil)
        limit = effective_limit(limit)
        blocks = next_blocks(limit)

        @logger.info(
          "[processing_runner] start count=#{blocks.size} limit=#{limit}"
        )

        enqueued = 0

        blocks.each do |block|
          enqueued += 1 if enqueue(block)
        end

        {
          enqueued: enqueued,
          selected: blocks.size,
          limit: limit,
          next_height: blocks.last&.height
        }
      end

      private

      def effective_limit(limit)
        explicit = limit.to_i if limit

        return explicit if explicit.to_i.positive?

        env_limit = ENV.fetch(ENV_KEY, DEFAULT_BATCH).to_i
        env_limit.positive? ? env_limit : DEFAULT_BATCH
      end

      def next_blocks(limit)
        BlockBufferModel
          .where(status: [
            Blockchain::Buffer::BlockBuffer::PENDING,
            Blockchain::Buffer::BlockBuffer::FAILED
          ])
          .order(:height)
          .limit(limit)
      end

      def enqueue(block)
        return false unless Blockchain::Buffer::BlockBuffer.mark_enqueued(block.height)

        Blockchain::Jobs::BlockProcessJob.perform_async(block.height)
        true
      end
    end
  end
end