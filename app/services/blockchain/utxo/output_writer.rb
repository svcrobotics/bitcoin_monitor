# frozen_string_literal: true

module Blockchain
  module Utxo
    class OutputWriter
      def initialize(logger: Rails.logger, buffer: Blockchain::Buffers::OutputBuffer.new)
        @logger = logger
        @buffer = buffer
      end

      def call(tx, context)
        rows = build_rows(tx, context)
        return 0 if rows.empty?

        @buffer.push_many(rows)
      rescue StandardError => e
        @logger.error("[output_writer] error txid=#{tx[:txid]} #{e.class}: #{e.message}")
        raise
      end

      def build_rows(tx, context)
        now = Time.current

        tx[:outputs].map do |output|
          {
            txid: tx[:txid],
            vout: output[:vout],
            address: output[:address],
            amount_btc: output[:value],
            block_height: context[:block_height],
            block_hash: context[:block_hash],
            block_time: normalize_time(context[:block_time]),
            created_at: now,
            updated_at: now
          }
        end
      end

      private

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return Time.at(value).in_time_zone if value.present?

        nil
      end
    end
  end
end