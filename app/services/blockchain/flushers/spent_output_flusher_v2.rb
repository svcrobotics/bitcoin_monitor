# frozen_string_literal: true

require "csv"
require "securerandom"

module Blockchain
  module Flushers
    class SpentOutputFlusherV2
      KEY = Blockchain::Buffers::SpentOutputBuffer::KEY
      DEFAULT_BATCH_SIZE = 20_000
      MODES = Blockchain::Flushers::SpentOutputFlusherSelector::MODES

      COLUMNS = %w[
        txid
        vout
        spent_txid
        spent_block_height
        prevout_address
        prevout_amount_btc
        prevout_block_height
      ].freeze

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
        timings = {}
        rows = []
        committed = false

        rows = measure_stage("pop_batch", timings) { pop_batch }
        return empty_result if rows.empty?

        temp_table = "tmp_layer1_spent_#{SecureRandom.hex(8)}"

        connection = ActiveRecord::Base.connection
        raw = connection.raw_connection

        tx_updated = 0
        utxo_deleted = 0
        cluster_inserted = 0

        begin
          ActiveRecord::Base.transaction do
            measure_stage("create_temp_table", timings) do
              create_temp_table(connection, temp_table)
            end

            measure_stage("copy_rows", timings) do
              copy_rows(raw, temp_table, rows)
            end

            measure_stage("analyze_temp_table", timings) do
              connection.execute("ANALYZE #{temp_table}")
            end

            unless tx_outputs_update_deferred?
              tx_updated =
                measure_stage("bulk_update_tx_outputs", timings) do
                  update_tx_outputs_from_temp(connection, temp_table)
                end
            end

            cluster_inserted =
              measure_stage("bulk_upsert_cluster_inputs", timings) do
                upsert_cluster_inputs_from_temp(connection, temp_table)
              end

            utxo_deleted =
              measure_stage("bulk_delete_utxo_outputs", timings) do
                delete_utxo_outputs_from_temp(connection, temp_table)
              end
          end

          committed = true
        ensure
          begin
            connection.execute("DROP TABLE IF EXISTS #{temp_table}")
          rescue StandardError
            nil
          end
        end

        duration_ms = monotonic_ms - started_at

        @logger.info(
          "[spent_output_flusher_v2] flushed=#{rows.size} " \
          "tx_updated=#{tx_updated} " \
          "tx_update_mode=#{tx_outputs_update_deferred? ? 'async' : 'inline'} " \
          "cluster_inserted=#{cluster_inserted} " \
          "utxo_deleted=#{utxo_deleted} " \
          "missing_tx=#{tx_outputs_update_deferred? ? 'deferred' : rows.size - tx_updated} " \
          "missing_utxo=#{rows.size - utxo_deleted} " \
          "batch_size=#{batch_size} " \
          "duration_ms=#{duration_ms} " \
          "stage_timings=#{timings.inspect}"
        )

        {
          ok: true,
          flushed: rows.size,
          tx_updated: tx_updated,
          tx_update_deferred: tx_outputs_update_deferred?,
          cluster_inserted: cluster_inserted,
          utxo_deleted: utxo_deleted,
          missing_tx: (rows.size - tx_updated unless tx_outputs_update_deferred?),
          missing_utxo: rows.size - utxo_deleted,
          duration_ms: duration_ms,
          stage_timings: timings
        }
      rescue StandardError => e
        requeue_rows(rows) if rows.any? && !committed

        @logger.error(
          "[spent_output_flusher_v2] failed rows=#{rows.size} " \
          "requeued=#{rows.any? && !committed} error=#{e.class}: #{e.message}"
        )

        raise
      end

      private

      def empty_result
        {
          ok: true,
          flushed: 0,
          tx_updated: 0,
          tx_update_deferred: tx_outputs_update_deferred?,
          cluster_inserted: 0,
          utxo_deleted: 0,
          missing_tx: 0,
          missing_utxo: 0,
          duration_ms: 0,
          stage_timings: {}
        }
      end


      def tx_outputs_update_deferred?
        Layer1::TxOutputsSpentSync::Config.enabled?
      end

      def normalize_mode(value)
        normalized = value.to_sym
        return normalized if MODES.include?(normalized)

        raise ArgumentError, "unknown spent output flusher mode #{value.inspect}"
      rescue NoMethodError
        raise ArgumentError, "unknown spent output flusher mode #{value.inspect}"
      end

      def batch_size
        ENV.fetch("SPENT_OUTPUT_FLUSH_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i
      end

      def pop_batch
        payloads = @redis.lpop(KEY, batch_size)
        Array(payloads).map { |payload| JSON.parse(payload) }
      end

      def requeue_rows(rows)
        payloads = rows.reverse.map { |row| JSON.generate(row) }
        @redis.lpush(KEY, *payloads) if payloads.any?
      end

      def create_temp_table(connection, temp_table)
        connection.execute(<<~SQL)
          CREATE TEMP TABLE #{temp_table} (
            txid text NOT NULL,
            vout integer NOT NULL,
            spent_txid text,
            spent_block_height integer NOT NULL,
            prevout_address text,
            prevout_amount_btc numeric(20, 8),
            prevout_block_height integer
          )
        SQL
      end

      def copy_rows(raw, temp_table, rows)
        raw.copy_data("COPY #{temp_table} (#{COLUMNS.join(", ")}) FROM STDIN WITH (FORMAT csv)") do
          rows.each do |row|
            raw.put_copy_data(
              CSV.generate_line(
                [
                  row["txid"],
                  row["vout"].to_i,
                  row["spent_txid"],
                  row["spent_block_height"].to_i,
                  row["prevout_address"],
                  row["prevout_amount_btc"],
                  row["prevout_block_height"]
                ]
              )
            )
          end
        end
      end

      def update_tx_outputs_from_temp(connection, temp_table)
        result = connection.exec_query(<<~SQL.squish)
          UPDATE tx_outputs AS txo
          SET
            spent = TRUE,
            spent_txid = data.spent_txid,
            spent_block_height = data.spent_block_height,
            updated_at = NOW()
          FROM #{temp_table} AS data
          WHERE txo.txid = data.txid
            AND txo.vout = data.vout
          RETURNING txo.id
        SQL

        result.rows.size
      end

      # Construit les ClusterInput directement dans PostgreSQL sans lire tx_outputs.
      #
      # Source stricte V5 : prevout fourni directement par Bitcoin Core
      # verbosity 3. utxo_outputs reste la table stricte des sorties live,
      # mais ne doit pas etre relue pour construire cluster_inputs.
      #
      # tx_outputs est une projection historique asynchrone et ne doit plus
      # participer au chemin de certification temps réel.
      def upsert_cluster_inputs_from_temp(connection, temp_table)
        result = connection.exec_query(<<~SQL.squish)
          WITH source_rows AS (
            SELECT DISTINCT ON (txid, vout)
              txid,
              vout,
              spent_txid,
              spent_block_height,
              prevout_address,
              prevout_amount_btc,
              prevout_block_height
            FROM #{temp_table}
            ORDER BY txid, vout
          ), resolved AS (
            SELECT
              data.txid,
              data.vout,
              data.spent_txid,
              data.spent_block_height,
              data.prevout_block_height AS block_height,
              NULLIF(BTRIM(data.prevout_address), '') AS address,
              data.prevout_amount_btc AS amount_btc
            FROM source_rows AS data
          ), eligible AS (
            SELECT *
            FROM resolved
            WHERE block_height IS NOT NULL
              AND address IS NOT NULL
              AND amount_btc IS NOT NULL
          )
          INSERT INTO cluster_inputs (
            block_height,
            txid,
            vout,
            address,
            amount_btc,
            spent,
            spent_txid,
            spent_block_height,
            address_balance_btc,
            address_received_btc,
            address_sent_btc,
            created_at,
            updated_at
          )
          SELECT
            eligible.block_height,
            eligible.txid,
            eligible.vout,
            eligible.address,
            eligible.amount_btc,
            TRUE,
            eligible.spent_txid,
            eligible.spent_block_height,
            stats.net_btc,
            stats.received_btc,
            stats.sent_btc,
            NOW(),
            NOW()
          FROM eligible
          LEFT JOIN address_flow_stats AS stats
            ON stats.address = eligible.address
          ON CONFLICT (txid, vout) DO UPDATE SET
            block_height = EXCLUDED.block_height,
            address = EXCLUDED.address,
            amount_btc = EXCLUDED.amount_btc,
            spent = EXCLUDED.spent,
            spent_txid = EXCLUDED.spent_txid,
            spent_block_height = EXCLUDED.spent_block_height,
            address_balance_btc = EXCLUDED.address_balance_btc,
            address_received_btc = EXCLUDED.address_received_btc,
            address_sent_btc = EXCLUDED.address_sent_btc,
            updated_at = EXCLUDED.updated_at
          WHERE ROW(
            cluster_inputs.block_height,
            cluster_inputs.address,
            cluster_inputs.amount_btc,
            cluster_inputs.spent,
            cluster_inputs.spent_txid,
            cluster_inputs.spent_block_height,
            cluster_inputs.address_balance_btc,
            cluster_inputs.address_received_btc,
            cluster_inputs.address_sent_btc
          ) IS DISTINCT FROM ROW(
            EXCLUDED.block_height,
            EXCLUDED.address,
            EXCLUDED.amount_btc,
            EXCLUDED.spent,
            EXCLUDED.spent_txid,
            EXCLUDED.spent_block_height,
            EXCLUDED.address_balance_btc,
            EXCLUDED.address_received_btc,
            EXCLUDED.address_sent_btc
          )
          RETURNING id
        SQL

        result.rows.size
      end

      def delete_utxo_outputs_from_temp(connection, temp_table)
        result = connection.exec_query(<<~SQL.squish)
          DELETE FROM utxo_outputs AS uo
          USING #{temp_table} AS data
          WHERE uo.txid = data.txid
            AND uo.vout = data.vout
          RETURNING uo.id
        SQL

        result.rows.size
      end

      def measure_stage(stage, timings)
        started_at = monotonic_ms
        result = yield
        duration_ms = monotonic_ms - started_at

        timings[stage.to_sym] = duration_ms

        @logger.info(
          "[spent_output_flusher_v2_timing] stage=#{stage} duration_ms=#{duration_ms}"
        )

        result
      rescue StandardError => e
        duration_ms = monotonic_ms - started_at
        timings[stage.to_sym] = duration_ms

        @logger.error(
          "[spent_output_flusher_v2_timing] stage_failed=#{stage} " \
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
