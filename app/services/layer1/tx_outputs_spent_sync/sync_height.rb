# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class SyncHeight
      def self.call(sync_record:, batch_size: Config.batch_size, logger: Rails.logger)
        new(sync_record: sync_record, batch_size: batch_size, logger: logger).call
      end

      def initialize(sync_record:, batch_size:, logger:)
        @sync_record = sync_record
        @height = sync_record.height.to_i
        @batch_size = [batch_size.to_i, 1].max
        @logger = logger
      end

      def call
        started_at = monotonic_ms
        result =
          Layer1TxOutputSync.transaction do
            @sync_record.lock!
            mark_processing!

            inputs_count = inputs_count_for_height
            matching_count = matching_tx_outputs_count
            rows_updated = update_one_batch
            remaining_rows = remaining_mismatches_count
            duration_ms = monotonic_ms - started_at

            status = remaining_rows.zero? ? "synced" : "pending"

            @sync_record.update!(
              status: status,
              attempts: 0,
              inputs_count: inputs_count,
              matching_tx_outputs_count: matching_count,
              rows_updated: @sync_record.rows_updated.to_i + rows_updated,
              remaining_rows: remaining_rows,
              duration_ms: @sync_record.duration_ms.to_i + duration_ms,
              completed_at: (Time.current if status == "synced"),
              last_error: nil
            )

            {
              ok: true,
              height: @height,
              status: status,
              inputs_count: inputs_count,
              matching_tx_outputs_count: matching_count,
              rows_updated: rows_updated,
              total_rows_updated: @sync_record.rows_updated,
              remaining_rows: remaining_rows,
              batch_size: @batch_size,
              duration_ms: duration_ms
            }
          end

        @logger.info("[tx_outputs_spent_sync] #{result.inspect}")
        result
      rescue StandardError => e
        duration_ms = monotonic_ms - started_at

        @sync_record.update_columns(
          status: "failed",
          attempts: @sync_record.attempts.to_i + 1,
          duration_ms: @sync_record.duration_ms.to_i + duration_ms,
          last_attempt_at: Time.current,
          last_error: "#{e.class}: #{e.message}".first(2_000),
          updated_at: Time.current
        )

        @logger.error(
          "[tx_outputs_spent_sync] failed height=#{@height} " \
          "duration_ms=#{duration_ms} error=#{e.class}: #{e.message}"
        )

        raise
      end

      private

      def mark_processing!
        @sync_record.update!(
          status: "processing",
          started_at: Time.current,
          last_attempt_at: Time.current,
          last_error: nil
        )
      end

      def inputs_count_for_height
        ClusterInput.where(spent_block_height: @height).count
      end

      def matching_tx_outputs_count
        sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish,
            SELECT COUNT(*)
            FROM cluster_inputs ci
            INNER JOIN tx_outputs txo
              ON txo.txid = ci.txid
             AND txo.vout = ci.vout
            WHERE ci.spent_block_height = ?
          SQL
          @height
        ])

        ActiveRecord::Base.connection.select_value(sql).to_i
      end

      def update_one_batch
        sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish,
            WITH batch AS MATERIALIZED (
              SELECT
                ci.txid,
                ci.vout,
                ci.spent_txid,
                ci.spent_block_height
              FROM cluster_inputs ci
              INNER JOIN tx_outputs txo
                ON txo.txid = ci.txid
               AND txo.vout = ci.vout
              WHERE ci.spent_block_height = ?
                AND (
                  txo.spent IS DISTINCT FROM TRUE
                  OR txo.spent_txid IS DISTINCT FROM ci.spent_txid
                  OR txo.spent_block_height IS DISTINCT FROM ci.spent_block_height
                )
              ORDER BY ci.id
              LIMIT ?
            )
            UPDATE tx_outputs AS txo
            SET
              spent = TRUE,
              spent_txid = batch.spent_txid,
              spent_block_height = batch.spent_block_height,
              updated_at = NOW()
            FROM batch
            WHERE txo.txid = batch.txid
              AND txo.vout = batch.vout
            RETURNING txo.id
          SQL
          @height,
          @batch_size
        ])

        ActiveRecord::Base.connection.exec_query(sql).rows.size
      end

      def remaining_mismatches_count
        sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish,
            SELECT COUNT(*)
            FROM cluster_inputs ci
            INNER JOIN tx_outputs txo
              ON txo.txid = ci.txid
             AND txo.vout = ci.vout
            WHERE ci.spent_block_height = ?
              AND (
                txo.spent IS DISTINCT FROM TRUE
                OR txo.spent_txid IS DISTINCT FROM ci.spent_txid
                OR txo.spent_block_height IS DISTINCT FROM ci.spent_block_height
              )
          SQL
          @height
        ])

        ActiveRecord::Base.connection.select_value(sql).to_i
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end
