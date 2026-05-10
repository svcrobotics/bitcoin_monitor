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

        sql = <<~SQL.squish
          UPDATE tx_outputs AS txo
          SET
            spent = TRUE,
            spent_txid = data.spent_txid,
            spent_block_height = data.spent_block_height,
            updated_at = #{ActiveRecord::Base.connection.quote(now)}
          FROM (
            VALUES #{values_sql}
          ) AS data(txid, vout, spent_txid, spent_block_height)
          WHERE txo.txid = data.txid
            AND txo.vout = data.vout
        SQL

        ActiveRecord::Base.connection.execute(sql)
      end
    end
  end
end