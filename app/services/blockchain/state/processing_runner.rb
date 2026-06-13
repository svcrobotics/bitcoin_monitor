# frozen_string_literal: true

module Blockchain
  module State
    class ProcessingRunner
      DEFAULT_BATCH = 10
      ENV_KEY = "LAYER1_PROCESSING_BATCH_SIZE"
      STUCK_AFTER_SECONDS = 120

      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def call(limit: nil)
        limit = effective_limit(limit)
        blocks = next_blocks(limit)

        @logger.info("[processing_runner] start count=#{blocks.size} limit=#{limit}")

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
        statuses = [
          Blockchain::Buffer::BlockBuffer::PENDING,
          Blockchain::Buffer::BlockBuffer::FAILED
        ]

        fresh_blocks = BlockBufferModel
          .where(status: statuses)

        stuck_blocks = BlockBufferModel
          .where(status: Blockchain::Buffer::BlockBuffer::ENQUEUED)
          .where("updated_at < ?", STUCK_AFTER_SECONDS.seconds.ago)

        ids = fresh_blocks.or(stuck_blocks).order(:height).limit(limit).pluck(:id)

        BlockBufferModel.where(id: ids).order(:height)
      end

      def enqueue(block)
        Blockchain::Jobs::BlockProcessJob.perform_async(block.height)
        block.update!(status: Blockchain::Buffer::BlockBuffer::ENQUEUED)
        true
      end
    end
  end
end