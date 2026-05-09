# frozen_string_literal: true

module Blockchain
  module Orchestration
    class RequeueStuckBlocks
      DEFAULT_STUCK_AFTER = 15.minutes

      def initialize(stuck_after: DEFAULT_STUCK_AFTER, logger: Rails.logger)
        @stuck_after = stuck_after
        @logger = logger
      end

      def call
        cutoff = Time.current - @stuck_after

        stuck_blocks = stuck_scope(cutoff).to_a
        heights = stuck_blocks.map(&:height)

        requeued_count =
          if heights.any?
            BlockBufferModel
              .where(height: heights)
              .update_all(
                status: "pending",
                processing_started_at: nil,
                last_heartbeat_at: nil,
                updated_at: Time.current
              )
          else
            0
          end

        @logger.info(
          "[requeue_stuck_blocks] requeued=#{requeued_count} " \
          "cutoff=#{cutoff.iso8601} heights=#{heights.join(',')}"
        )

        {
          ok: true,
          requeued_count: requeued_count,
          heights: heights
        }
      end

      private

      def stuck_scope(cutoff)
        BlockBufferModel
          .where(status: "processing")
          .where(
            <<~SQL.squish,
              COALESCE(last_heartbeat_at, processing_started_at, updated_at) < ?
            SQL
            cutoff
          )
          .order(:height)
      end
    end
  end
end