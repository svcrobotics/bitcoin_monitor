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

        utxo_deleted = 0
        cluster_result = empty_cluster_result

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

            cluster_result =
              measure_stage("bulk_upsert_cluster_inputs", timings) do
                upsert_cluster_inputs_from_temp(connection, temp_table, timings)
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
          "tx_updated=0 " \
          "tx_update_mode=deferred " \
          "cluster_mode=#{cluster_result[:mode]} " \
          "cluster_inserted=#{cluster_result[:inserted]} " \
          "cluster_conflicts=#{cluster_result[:conflicts]} " \
          "cluster_conflicts_identical=#{cluster_result[:identical]} " \
          "cluster_conflicts_divergent=#{cluster_result[:divergent]} " \
          "utxo_deleted=#{utxo_deleted} " \
          "missing_tx=deferred " \
          "missing_utxo=#{rows.size - utxo_deleted} " \
          "batch_size=#{batch_size} " \
          "duration_ms=#{duration_ms} " \
          "stage_timings=#{timings.inspect}"
        )

        {
          ok: true,
          flushed: rows.size,
          tx_updated: 0,
          tx_update_deferred: true,
          cluster_inserted: cluster_result[:inserted],
          cluster_conflicts: cluster_result[:conflicts],
          cluster_conflicts_identical: cluster_result[:identical],
          cluster_conflicts_divergent: cluster_result[:divergent],
          cluster_mode: cluster_result[:mode],
          utxo_deleted: utxo_deleted,
          missing_tx: nil,
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
          tx_update_deferred: true,
          cluster_inserted: 0,
          cluster_conflicts: 0,
          cluster_conflicts_identical: 0,
          cluster_conflicts_divergent: 0,
          cluster_mode: mode,
          utxo_deleted: 0,
          missing_tx: 0,
          missing_utxo: 0,
          duration_ms: 0,
          stage_timings: {}
        }
      end
      def normalize_mode(value)
        normalized = value.to_sym
        return normalized if MODES.include?(normalized)

        raise ArgumentError, "unknown spent output flusher mode #{value.inspect}"
      rescue NoMethodError
        raise ArgumentError, "unknown spent output flusher mode #{value.inspect}"
      end

      def realtime?
        mode == :realtime
      end

      def empty_cluster_result
        {
          inserted: 0,
          conflicts: 0,
          identical: 0,
          divergent: 0,
          mode: mode
        }
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

      # Construit les ClusterInput directement dans PostgreSQL sans lire tx_outputs.
      #
      # Source stricte V5 : prevout fourni directement par Bitcoin Core
      # verbosity 3. utxo_outputs reste la table stricte des sorties live,
      # mais ne doit pas etre relue pour construire cluster_inputs.
      #
      # tx_outputs est une projection historique asynchrone et ne doit plus
      # participer au chemin de certification temps réel.
      def upsert_cluster_inputs_from_temp(connection, temp_table, timings = nil)
        if realtime?
          insert_cluster_inputs_realtime(connection, temp_table, timings || {})
        else
          upsert_cluster_inputs_recovery(connection, temp_table)
        end
      end

      def cluster_inputs_source_cte(temp_table)
        <<~SQL
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
        SQL
      end

      def insert_cluster_inputs_realtime(connection, temp_table, timings)
        insert_counts =
          measure_stage("realtime_insert_cluster_inputs", timings) do
            realtime_insert_cluster_inputs(connection, temp_table)
          end

        inserted = insert_counts[:inserted_count]
        conflicts_count =
          insert_counts[:eligible_count] - insert_counts[:inserted_count]
        conflict_keys = insert_counts[:conflict_keys]

        conflicts = {
          conflicts: conflicts_count,
          identical: 0,
          divergent: 0
        }

        if conflicts_count.positive?
          conflicts =
            measure_stage("realtime_verify_conflicts", timings) do
              realtime_cluster_input_conflicts(
                connection,
                temp_table,
                conflict_keys
              )
            end

          unless conflicts[:conflicts] == conflicts_count
            raise(
              "cluster_inputs realtime conflict count mismatch " \
              "insert_conflicts=#{conflicts_count} " \
              "verified_conflicts=#{conflicts[:conflicts]}"
            )
          end
        end

        if conflicts[:divergent].positive?
          samples =
            divergent_cluster_input_samples(
              connection,
              temp_table,
              conflict_keys
            )

          raise(
            "divergent cluster_inputs in realtime spent flusher " \
            "count=#{conflicts[:divergent]} samples=#{samples.inspect}"
          )
        end

        {
          inserted: inserted,
          conflicts: conflicts[:conflicts],
          identical: conflicts[:identical],
          divergent: conflicts[:divergent],
          mode: mode
        }
      end

      def realtime_insert_cluster_inputs(connection, temp_table)
        result = connection.exec_query(<<~SQL.squish)
          #{cluster_inputs_source_cte(temp_table)}
          , inserted AS (
            INSERT INTO cluster_inputs (
              block_height,
              txid,
              vout,
              address,
              amount_btc,
              spent,
              spent_txid,
              spent_block_height,
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
              NOW(),
              NOW()
            FROM eligible
            ON CONFLICT (txid, vout) DO NOTHING
            RETURNING txid, vout
          )
          SELECT
            (SELECT COUNT(*) FROM eligible)::integer AS eligible_count,
            (SELECT COUNT(*) FROM inserted)::integer AS inserted_count,
            COALESCE(
              (
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'txid',
                    eligible.txid,
                    'vout',
                    eligible.vout
                  )
                  ORDER BY eligible.txid, eligible.vout
                )
                FROM eligible
                LEFT JOIN inserted
                  ON inserted.txid = eligible.txid
                 AND inserted.vout = eligible.vout
                WHERE inserted.txid IS NULL
              ),
              '[]'::jsonb
            ) AS conflict_keys
        SQL

        row = result.first || {}

        {
          eligible_count: row["eligible_count"].to_i,
          inserted_count: row["inserted_count"].to_i,
          conflict_keys: normalize_conflict_keys(row["conflict_keys"])
        }
      end

      def realtime_cluster_input_conflicts(connection, temp_table, conflict_keys)
        result = connection.exec_query(<<~SQL.squish)
          #{cluster_inputs_source_cte(temp_table)}
          , #{conflict_keys_cte(connection, conflict_keys)}
          SELECT
            COUNT(*)::integer AS conflicts,
            COUNT(*) FILTER (
              WHERE ROW(
                cluster_inputs.block_height,
                cluster_inputs.address,
                cluster_inputs.amount_btc,
                cluster_inputs.spent,
                cluster_inputs.spent_txid,
                cluster_inputs.spent_block_height
              ) IS NOT DISTINCT FROM ROW(
                eligible.block_height,
                eligible.address,
                eligible.amount_btc,
                TRUE,
                eligible.spent_txid,
                eligible.spent_block_height
              )
            )::integer AS identical,
            COUNT(*) FILTER (
              WHERE ROW(
                cluster_inputs.block_height,
                cluster_inputs.address,
                cluster_inputs.amount_btc,
                cluster_inputs.spent,
                cluster_inputs.spent_txid,
                cluster_inputs.spent_block_height
              ) IS DISTINCT FROM ROW(
                eligible.block_height,
                eligible.address,
                eligible.amount_btc,
                TRUE,
                eligible.spent_txid,
                eligible.spent_block_height
              )
            )::integer AS divergent
          FROM eligible
          INNER JOIN conflict_keys
            ON conflict_keys.txid = eligible.txid
           AND conflict_keys.vout = eligible.vout
          INNER JOIN cluster_inputs
            ON cluster_inputs.txid = eligible.txid
           AND cluster_inputs.vout = eligible.vout
        SQL

        row = result.first || {}

        {
          conflicts: row["conflicts"].to_i,
          identical: row["identical"].to_i,
          divergent: row["divergent"].to_i
        }
      end

      def divergent_cluster_input_samples(connection, temp_table, conflict_keys)
        connection.exec_query(<<~SQL.squish).to_a
          #{cluster_inputs_source_cte(temp_table)}
          , #{conflict_keys_cte(connection, conflict_keys)}
          SELECT
            eligible.txid,
            eligible.vout,
            cluster_inputs.block_height AS existing_block_height,
            eligible.block_height AS incoming_block_height,
            cluster_inputs.address AS existing_address,
            eligible.address AS incoming_address,
            cluster_inputs.amount_btc AS existing_amount_btc,
            eligible.amount_btc AS incoming_amount_btc,
            cluster_inputs.spent AS existing_spent,
            TRUE AS incoming_spent,
            cluster_inputs.spent_txid AS existing_spent_txid,
            eligible.spent_txid AS incoming_spent_txid,
            cluster_inputs.spent_block_height AS existing_spent_block_height,
            eligible.spent_block_height AS incoming_spent_block_height
          FROM eligible
          INNER JOIN conflict_keys
            ON conflict_keys.txid = eligible.txid
           AND conflict_keys.vout = eligible.vout
          INNER JOIN cluster_inputs
            ON cluster_inputs.txid = eligible.txid
           AND cluster_inputs.vout = eligible.vout
          WHERE ROW(
            cluster_inputs.block_height,
            cluster_inputs.address,
            cluster_inputs.amount_btc,
            cluster_inputs.spent,
            cluster_inputs.spent_txid,
            cluster_inputs.spent_block_height
          ) IS DISTINCT FROM ROW(
            eligible.block_height,
            eligible.address,
            eligible.amount_btc,
            TRUE,
            eligible.spent_txid,
            eligible.spent_block_height
          )
          ORDER BY eligible.txid, eligible.vout
          LIMIT 5
        SQL
      end

      def normalize_conflict_keys(value)
        keys =
          case value
          when String
            JSON.parse(value)
          when Array
            value
          when nil
            []
          else
            value.to_a
          end

        keys.map do |key|
          {
            "txid" => key.fetch("txid"),
            "vout" => key.fetch("vout").to_i
          }
        end
      end

      def conflict_keys_cte(connection, conflict_keys)
        if conflict_keys.empty?
          return(
            "conflict_keys(txid, vout) AS " \
            "(SELECT NULL::text, NULL::integer WHERE FALSE)"
          )
        end

        values =
          conflict_keys.map do |key|
            txid = connection.quote(key.fetch("txid"))
            vout = Integer(key.fetch("vout"))

            "(#{txid}, #{vout})"
          end

        "conflict_keys(txid, vout) AS (VALUES #{values.join(', ')})"
      end

      def upsert_cluster_inputs_recovery(connection, temp_table)
        result = connection.exec_query(<<~SQL.squish)
          #{cluster_inputs_source_cte(temp_table)}
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

        {
          inserted: result.rows.size,
          conflicts: 0,
          identical: 0,
          divergent: 0,
          mode: mode
        }
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
