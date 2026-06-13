# frozen_string_literal: true

module Blockchain
  module Flushers
    class SpentOutputFlusher
      KEY = Blockchain::Buffers::SpentOutputBuffer::KEY
      BATCH_SIZE = ENV.fetch("SPENT_OUTPUT_FLUSH_BATCH_SIZE", 5_000).to_i

      def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")), logger: Rails.logger)
        @redis = redis
        @logger = logger
      end

      def call
        rows = pop_batch
        return { ok: true, flushed: 0 } if rows.empty?

        now = Time.current

        rows.each_slice(1_000) do |slice|
          update_slice(slice, now)
          Clusters::SpentUtxoConsumer.call(rows: slice)
          # apply_address_flow_stats(slice)
        end

        @logger.info("[spent_output_flusher] flushed=#{rows.size}")

        { ok: true, flushed: rows.size }
      end

      private

      def pop_batch
        payloads = @redis.lpop(KEY, BATCH_SIZE)
        payloads = Array(payloads)

        payloads.map { |payload| JSON.parse(payload) }
      end

      def update_slice(rows, now)
        values_sql = rows.map do |row|
          ActiveRecord::Base.sanitize_sql_array([
            "(?, ?, ?, ?)",
            row["txid"],
            row["vout"].to_i,
            row["spent_txid"],
            row["spent_block_height"].to_i
          ])
        end.join(", ")

        connection = ActiveRecord::Base.connection

        connection.execute(<<~SQL.squish)
          UPDATE tx_outputs AS txo
          SET
            spent = TRUE,
            spent_txid = data.spent_txid,
            spent_block_height = data.spent_block_height,
            updated_at = #{connection.quote(now)}
          FROM (
            VALUES #{values_sql}
          ) AS data(txid, vout, spent_txid, spent_block_height)
          WHERE txo.txid = data.txid
            AND txo.vout = data.vout
        SQL

        connection.execute(<<~SQL.squish)
          DELETE FROM utxo_outputs AS uo
          USING (
            VALUES #{values_sql}
          ) AS data(txid, vout, spent_txid, spent_block_height)
          WHERE uo.txid = data.txid
            AND uo.vout = data.vout
        SQL
      end

      def apply_address_flow_stats(rows)
        txid_vouts = rows.map { |row| [row["txid"], row["vout"].to_i] }
        return if txid_vouts.empty?

        conditions = txid_vouts.map do |txid, vout|
          ActiveRecord::Base.sanitize_sql_array(["(txid = ? AND vout = ?)", txid, vout])
        end.join(" OR ")

        outputs = TxOutput.where(conditions)

        result = AddressFlowStats::ApplySpentOutputs.call(outputs: outputs)

        @logger.info("[spent_output_flusher] address_flow_stats=#{result[:addresses]}")
      rescue => e
        @logger.error("[spent_output_flusher] address_flow_stats_error=#{e.class}: #{e.message}")
      end
    end
  end
end