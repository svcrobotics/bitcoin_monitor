# frozen_string_literal: true

module Blockchain
  module Flushers
    class SpentOutputFlusher
      KEY = Blockchain::Buffers::SpentOutputBuffer::KEY
      DEFAULT_BATCH_SIZE = 5_000
      SLICE_SIZE = 1_000

      def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")), logger: Rails.logger)
        @redis = redis
        @logger = logger
      end

      def call
        started_at = monotonic_ms

        rows = measure_stage("pop_batch") { pop_batch }
        return empty_result if rows.empty?

        tx_updated = 0
        utxo_deleted = 0
        cluster_inserted = 0
        slice_timings = []

        rows.each_slice(SLICE_SIZE).with_index(1) do |slice, index|
          slice_started_at = monotonic_ms
          timings = {}

          tx_updated +=
            measure_stage("slice_#{index}_update_tx_outputs", timings) do
              update_tx_outputs(slice)
            end

          consumer_result =
            measure_stage("slice_#{index}_spent_utxo_consumer", timings) do
              Clusters::SpentUtxoConsumer.call(rows: slice)
            end

          cluster_inserted += consumer_result[:inserted].to_i

          utxo_deleted +=
            measure_stage("slice_#{index}_delete_utxo_outputs", timings) do
              delete_utxo_outputs(slice)
            end

          slice_duration_ms = monotonic_ms - slice_started_at

          slice_timings << {
            slice: index,
            rows: slice.size,
            duration_ms: slice_duration_ms,
            timings: timings
          }

          @logger.info(
            "[spent_output_flusher_slice] slice=#{index} rows=#{slice.size} " \
            "duration_ms=#{slice_duration_ms} timings=#{timings.inspect}"
          )
        end

        duration_ms = monotonic_ms - started_at

        @logger.info(
          "[spent_output_flusher] flushed=#{rows.size} " \
          "tx_updated=#{tx_updated} " \
          "cluster_inserted=#{cluster_inserted} " \
          "utxo_deleted=#{utxo_deleted} " \
          "missing_tx=#{rows.size - tx_updated} " \
          "missing_utxo=#{rows.size - utxo_deleted} " \
          "batch_size=#{batch_size} " \
          "duration_ms=#{duration_ms} " \
          "slice_timings=#{slice_timings.inspect}"
        )

        {
          ok: true,
          flushed: rows.size,
          tx_updated: tx_updated,
          cluster_inserted: cluster_inserted,
          utxo_deleted: utxo_deleted,
          missing_tx: rows.size - tx_updated,
          missing_utxo: rows.size - utxo_deleted,
          duration_ms: duration_ms,
          slice_timings: slice_timings
        }
      end

      private

      def empty_result
        {
          ok: true,
          flushed: 0,
          tx_updated: 0,
          cluster_inserted: 0,
          utxo_deleted: 0,
          missing_tx: 0,
          missing_utxo: 0,
          duration_ms: 0,
          slice_timings: []
        }
      end

      def batch_size
        ENV.fetch("SPENT_OUTPUT_FLUSH_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i
      end

      def pop_batch
        payloads = @redis.lpop(KEY, batch_size)
        Array(payloads).map { |payload| JSON.parse(payload) }
      end

      def values_sql(rows)
        rows.map do |row|
          ActiveRecord::Base.sanitize_sql_array([
            "(?, ?, ?, ?)",
            row["txid"],
            row["vout"].to_i,
            row["spent_txid"],
            row["spent_block_height"].to_i
          ])
        end.join(", ")
      end

      def update_tx_outputs(rows)
        sql_values = values_sql(rows)
        connection = ActiveRecord::Base.connection

        result = connection.exec_query(<<~SQL.squish)
          UPDATE tx_outputs AS txo
          SET
            spent = TRUE,
            spent_txid = data.spent_txid,
            spent_block_height = data.spent_block_height,
            updated_at = NOW()
          FROM (
            VALUES #{sql_values}
          ) AS data(txid, vout, spent_txid, spent_block_height)
          WHERE txo.txid = data.txid
            AND txo.vout = data.vout
          RETURNING txo.id
        SQL

        result.rows.size
      end

      def delete_utxo_outputs(rows)
        sql_values = values_sql(rows)
        connection = ActiveRecord::Base.connection

        result = connection.exec_query(<<~SQL.squish)
          DELETE FROM utxo_outputs AS uo
          USING (
            VALUES #{sql_values}
          ) AS data(txid, vout, spent_txid, spent_block_height)
          WHERE uo.txid = data.txid
            AND uo.vout = data.vout
          RETURNING uo.id
        SQL

        result.rows.size
      end

      def measure_stage(stage, timings = nil)
        started_at = monotonic_ms
        result = yield
        duration_ms = monotonic_ms - started_at

        timings[stage.to_sym] = duration_ms if timings
        @logger.info("[spent_output_flusher_timing] stage=#{stage} duration_ms=#{duration_ms}")

        result
      rescue StandardError => e
        duration_ms = monotonic_ms - started_at
        timings[stage.to_sym] = duration_ms if timings

        @logger.error(
          "[spent_output_flusher_timing] stage_failed=#{stage} " \
          "duration_ms=#{duration_ms} error=#{e.class}: #{e.message}"
        )

        raise
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end
