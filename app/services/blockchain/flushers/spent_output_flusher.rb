# frozen_string_literal: true

module Blockchain
  module Flushers
    class SpentOutputFlusher
      KEY = Blockchain::Buffers::SpentOutputBuffer::KEY
      DEFAULT_BATCH_SIZE = 5_000
      SLICE_SIZE = 1_000
      MODES = Blockchain::Flushers::SpentOutputFlusherSelector::MODES

      attr_reader :mode

      def initialize(
        redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")),
        logger: Rails.logger,
        mode: :recovery
      )
        @redis = redis
        @logger = logger
        @mode = normalize_mode(mode)
      end

      def call
        started_at = monotonic_ms
        rows = []
        committed_rows_count = 0

        rows = measure_stage("pop_batch") { pop_batch }
        return empty_result if rows.empty?

        tx_updated = 0
        utxo_deleted = 0
        cluster_inserted = 0
        slice_timings = []

        rows.each_slice(SLICE_SIZE).with_index(1) do |slice, index|
          slice_started_at = monotonic_ms
          timings = {}

          slice_tx_updated = 0
          slice_cluster_inserted = 0
          slice_utxo_deleted = 0

          ActiveRecord::Base.transaction do
            slice_tx_updated =
              measure_stage(
                "slice_#{index}_update_tx_outputs",
                timings
              ) do
                update_tx_outputs(slice)
              end

            consumer_result =
              measure_stage(
                "slice_#{index}_spent_utxo_consumer",
                timings
              ) do
                Clusters::SpentUtxoConsumer.call(rows: slice)
              end

            slice_cluster_inserted =
              consumer_result[:inserted].to_i

            slice_utxo_deleted =
              measure_stage(
                "slice_#{index}_delete_utxo_outputs",
                timings
              ) do
                delete_utxo_outputs(slice)
              end
          end

          # La slice est maintenant réellement validée et visible
          # depuis les autres connexions PostgreSQL.
          committed_rows_count += slice.size

          tx_updated += slice_tx_updated.to_i
          cluster_inserted += slice_cluster_inserted
          utxo_deleted += slice_utxo_deleted.to_i

          slice_duration_ms =
            monotonic_ms - slice_started_at

          heartbeat_slice(
            slice,
            index: index,
            duration_ms: slice_duration_ms
          )

          slice_timings << {
            slice: index,
            rows: slice.size,
            duration_ms: slice_duration_ms,
            timings: timings
          }

          @logger.info(
            "[spent_output_flusher_slice] " \
            "slice=#{index} " \
            "rows=#{slice.size} " \
            "committed_rows=#{committed_rows_count} " \
            "duration_ms=#{slice_duration_ms} " \
            "timings=#{timings.inspect}"
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
      rescue StandardError => e
        pending_rows =
          rows.drop(committed_rows_count)

        requeue_rows(pending_rows) if pending_rows.any?

        @logger.error(
          "[spent_output_flusher] failed " \
          "rows=#{rows.size} " \
          "committed_rows=#{committed_rows_count} " \
          "requeued_rows=#{pending_rows.size} " \
          "error=#{e.class}: #{e.message}"
        )

        raise
      end

      private

      def heartbeat_slice(rows, index:, duration_ms:)
        return unless mode == :realtime

        heights =
          rows
            .map { |row| row["spent_block_height"].to_i }
            .select(&:positive?)
            .uniq

        heights.each do |height|
          Blockchain::Buffer::BlockBuffer.heartbeat(height)
        end

        @logger.info(
          "[spent_output_flusher_heartbeat] " \
          "slice=#{index} " \
          "heights=#{heights.join(',')} " \
          "duration_ms=#{duration_ms}"
        )
      rescue StandardError => e
        # Une défaillance d'observabilité ne doit jamais annuler
        # une slice déjà validée.
        @logger.warn(
          "[spent_output_flusher_heartbeat] failed " \
          "slice=#{index} " \
          "error=#{e.class}: #{e.message}"
        )

        nil
      end

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

      def normalize_mode(value)
        normalized = value.to_sym
        return normalized if MODES.include?(normalized)

        raise ArgumentError, "unknown spent output flusher mode #{value.inspect}"
      rescue NoMethodError
        raise ArgumentError, "unknown spent output flusher mode #{value.inspect}"
      end

      def pop_batch
        payloads = @redis.lpop(KEY, batch_size)
        Array(payloads).map { |payload| JSON.parse(payload) }
      end

      def requeue_rows(rows)
        payloads = rows.reverse.map { |row| JSON.generate(row) }
        @redis.lpush(KEY, *payloads) if payloads.any?
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
