# frozen_string_literal: true

module Blockchain
  module Processing
    class SpentRowsBuilder
      def initialize(prevout_cache:, logger: Rails.logger)
        @prevout_cache = prevout_cache
        @logger = logger
      end

      def call(block, block_buffer)
        now = Time.current

        spent_rows = []
        tx_count = 0
        input_count = 0

        block.fetch("tx").each do |raw_tx|
          txid = raw_tx["txid"]
          inputs = raw_tx["vin"] || []

          tx_count += 1
          input_count += inputs.size

          inputs.each do |input|
            next if input["coinbase"].present?

            previous_txid = input["txid"]
            previous_vout = input["vout"]

            next if previous_txid.blank?
            next unless previous_vout.is_a?(Integer)

            prevout = @prevout_cache[[previous_txid, previous_vout]]
            next unless prevout

            spent_rows << {
              txid: previous_txid,
              vout: previous_vout,
              spent: true,
              spent_txid: txid,
              spent_block_height: block_buffer.height,
              updated_at: now
            }
          end
        end

        @logger.info(
          "[spent_rows_builder] height=#{block_buffer.height} " \
          "txs=#{tx_count} inputs=#{input_count} spent_rows=#{spent_rows.size}"
        )

        {
          spent_rows: spent_rows,
          tx_count: tx_count,
          input_count: input_count
        }
      end
    end
  end
end
