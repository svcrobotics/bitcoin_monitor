# frozen_string_literal: true

module Blockchain
  module Flushers
    class OutputFlusher
      KEY = Blockchain::Buffers::OutputBuffer::KEY
      BATCH_SIZE = ENV.fetch("OUTPUT_FLUSH_BATCH_SIZE", 2_000).to_i

      def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")), logger: Rails.logger)
        @redis = redis
        @logger = logger
      end

      def call
        rows = pop_batch
        return { ok: true, flushed: 0 } if rows.empty?

        TxOutput.upsert_all(
          rows,
          unique_by: :index_tx_outputs_on_txid_and_vout,
          update_only: [:address, :amount_btc, :block_height, :block_hash, :block_time]
        )

        apply_address_flow_stats(rows)

        @logger.info("[output_flusher] flushed=#{rows.size}")

        {
          ok: true,
          flushed: rows.size
        }
      end

      private

      def pop_batch
        payloads = @redis.lpop(KEY, BATCH_SIZE)
        payloads = Array(payloads)

        payloads.map { |payload| JSON.parse(payload) }
      end

      def apply_address_flow_stats(rows)
        txids = rows.map { |row| row["txid"] }.compact.uniq
        return if txids.empty?

        outputs = TxOutput.where(txid: txids)

        result = AddressFlowStats::ApplyOutputs.call(outputs: outputs)

        @logger.info("[output_flusher] address_flow_stats=#{result[:addresses]}")
      rescue => e
        @logger.error("[output_flusher] address_flow_stats_error=#{e.class}: #{e.message}")
      end
    end
  end
end