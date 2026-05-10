# frozen_string_literal: true

module Blockchain
  module Utxo
    class SpentOutputWriter
      def initialize(
        logger: Rails.logger,
        buffer: Blockchain::Buffers::SpentOutputBuffer.new
      )
        @logger = logger
        @buffer = buffer
      end

      def call(tx, inputs, context)
        rows = build_rows(tx, inputs, context)
        return 0 if rows.empty?

        @buffer.push_many(rows)
      rescue StandardError => e
        @logger.error("[spent_output_writer] error txid=#{tx[:txid]} #{e.class}: #{e.message}")
        raise
      end

      def build_rows(tx, inputs, context)
        now = Time.current

        inputs.filter_map do |input|
          next if input[:coinbase]

          {
            txid: input[:txid],
            vout: input[:vout],
            spent: true,
            spent_txid: tx[:txid],
            spent_block_height: context[:block_height],
            updated_at: now
          }
        end
      end
    end
  end
end