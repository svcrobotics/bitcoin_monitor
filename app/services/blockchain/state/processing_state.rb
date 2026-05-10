# frozen_string_literal: true

module Blockchain
  module State
    class ProcessingState
      def initialize
      end

      def call
        last_processed = BlockBufferModel
          .where(status: "processed")
          .maximum(:height)

        last_block = BlockBufferModel.maximum(:height)

        {
          last_processed_height: last_processed,
          last_seen_height: last_block,
          lag: compute_lag(last_block, last_processed),
          throughput: recent_throughput,
          errors: error_count
        }
      end

      private

      def compute_lag(seen, processed)
        return nil unless seen && processed
        seen - processed
      end

      def recent_throughput
        BlockBufferModel
          .where(status: "processed")
          .where("updated_at > ?", 5.minutes.ago)
          .count
      end

      def error_count
        BlockBufferModel.where(status: "failed").count
      end
    end
  end
end