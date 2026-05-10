# frozen_string_literal: true

module Blockchain
  module State
    class IngestionState
      def initialize(rpc: BitcoinRpc.new)
        @rpc = rpc
      end

      def call
        tip = @rpc.getblockcount
        last = BlockBufferModel.maximum(:height)

        {
          tip_height: tip,
          last_ingested_height: last,
          lag: compute_lag(tip, last),
          pending: count_by_status("pending"),
          processing: count_by_status("processing"),
          failed: count_by_status("failed")
        }
      end

      private

      def compute_lag(tip, last)
        return nil unless tip && last
        tip - last
      end

      def count_by_status(status)
        BlockBufferModel.where(status: status).count
      end
    end
  end
end