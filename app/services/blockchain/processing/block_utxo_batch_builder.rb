# frozen_string_literal: true

module Blockchain
  module Processing
    class BlockUtxoBatchBuilder
      def initialize(prevout_cache:, logger: Rails.logger)
        @prevout_cache = prevout_cache
        @logger = logger
      end

      def call(block, block_buffer)
        now = Time.current
        block_time = normalize_time(block["time"])

        output_rows = []
        spent_rows = []
        tx_count = 0
        input_count = 0
        output_count = 0

        block.fetch("tx").each_with_index do |raw_tx, tx_index|
          txid = raw_tx["txid"]
          outputs = raw_tx["vout"] || []
          inputs = raw_tx["vin"] || []

          tx_count += 1
          input_count += inputs.size
          output_count += outputs.size

          outputs.each_with_index do |output, fallback_vout|
            vout = output["n"] || fallback_vout
            address = extract_address(output)
            value = output["value"]

            output_rows << {
              txid: txid,
              vout: vout,
              address: address,
              amount_btc: value,
              block_height: block_buffer.height,
              block_hash: block_buffer.block_hash,
              block_time: block_time,
              created_at: now,
              updated_at: now
            }
          end

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

        result = {
          output_rows: output_rows,
          spent_rows: spent_rows,
          tx_count: tx_count,
          input_count: input_count,
          output_count: output_count
        }

        @logger.info(
          "[block_utxo_batch_builder] height=#{block_buffer.height} " \
          "txs=#{tx_count} inputs=#{input_count} outputs=#{output_count} " \
          "output_rows=#{output_rows.size} spent_rows=#{spent_rows.size}"
        )

        result
      end

      private

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return Time.at(value).in_time_zone if value.present?

        nil
      end

      def extract_address(output)
        script = output["scriptPubKey"] || {}

        return script["address"] if script["address"].present?
        return script["addresses"].first if script["addresses"].present?

        nil
      end
    end
  end
end