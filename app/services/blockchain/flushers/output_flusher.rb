# frozen_string_literal: true

require "csv"
require "securerandom"

module Blockchain
  module Flushers
    class OutputFlusher
      KEY = Blockchain::Buffers::OutputBuffer::KEY
      DEFAULT_BATCH_SIZE = 20_000

      COLUMNS = %w[
        txid
        vout
        address
        amount_btc
        block_height
        block_hash
        block_time
        spent
        spent_txid
        spent_block_height
        created_at
        updated_at
      ].freeze

      def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")), logger: Rails.logger)
        @redis = redis
        @logger = logger
      end

      def call
        started_at = monotonic_ms

        rows = measure_stage("pop_batch") { pop_batch }
        return empty_result if rows.empty?

        result = copy_insert(rows)
        duration_ms = monotonic_ms - started_at

        @logger.info(
          "[output_flusher] flushed=#{rows.size} " \
          "tx_inserted=#{result[:tx_inserted]} " \
          "utxo_inserted=#{result[:utxo_inserted]} " \
          "tx_skipped=#{rows.size - result[:tx_inserted]} " \
          "utxo_skipped=#{rows.size - result[:utxo_inserted]} " \
          "batch_size=#{batch_size} " \
          "duration_ms=#{duration_ms} " \
          "stage_timings=#{result[:stage_timings].inspect}"
        )

        {
          ok: true,
          flushed: rows.size,
          tx_inserted: result[:tx_inserted],
          utxo_inserted: result[:utxo_inserted],
          tx_skipped: rows.size - result[:tx_inserted],
          utxo_skipped: rows.size - result[:utxo_inserted],
          duration_ms: duration_ms,
          stage_timings: result[:stage_timings]
        }
      end

      private

      def empty_result
        {
          ok: true,
          flushed: 0,
          tx_inserted: 0,
          utxo_inserted: 0,
          tx_skipped: 0,
          utxo_skipped: 0,
          duration_ms: 0,
          stage_timings: {}
        }
      end

      def batch_size
        ENV.fetch("OUTPUT_FLUSH_BATCH_SIZE", DEFAULT_BATCH_SIZE).to_i
      end

      def pop_batch
        payloads = @redis.lpop(KEY, batch_size)
        Array(payloads).map { |payload| JSON.parse(payload) }
      end

      def copy_insert(rows)
        temp_table = "tmp_layer1_outputs_#{SecureRandom.hex(8)}"

        connection = ActiveRecord::Base.connection
        raw = connection.raw_connection

        tx_inserted = 0
        utxo_inserted = 0
        utxo_inserted_rows = nil
        stage_timings = {}

        connection.transaction do
          measure_stage("create_temp_table", stage_timings) do
            create_temp_table(connection, temp_table)
          end

          measure_stage("copy_rows", stage_timings) do
            copy_rows(raw, temp_table, rows)
          end

          tx_inserted =
            measure_stage("insert_tx_outputs", stage_timings) do
              insert_tx_outputs(connection, temp_table)
            end

          utxo_inserted_rows =
            measure_stage("insert_utxo_outputs", stage_timings) do
              insert_utxo_outputs(connection, temp_table)
            end

          utxo_inserted = utxo_inserted_rows.rows.size
        end

        {
          tx_inserted: tx_inserted,
          utxo_inserted: utxo_inserted,
          stage_timings: stage_timings
        }
      end

      def create_temp_table(connection, temp_table)
        connection.execute(<<~SQL)
          CREATE TEMP TABLE #{temp_table} (
            txid text NOT NULL,
            vout integer NOT NULL,
            address text,
            amount_btc numeric,
            block_height integer,
            block_hash text,
            block_time timestamp,
            spent boolean,
            spent_txid text,
            spent_block_height integer,
            created_at timestamp NOT NULL,
            updated_at timestamp NOT NULL
          ) ON COMMIT DROP
        SQL
      end

      def copy_rows(raw, temp_table, rows)
        raw.copy_data("COPY #{temp_table} (#{COLUMNS.join(", ")}) FROM STDIN WITH (FORMAT csv)") do
          rows.each do |row|
            raw.put_copy_data(
              CSV.generate_line(
                [
                  row["txid"],
                  row["vout"],
                  row["address"],
                  row["amount_btc"],
                  row["block_height"],
                  row["block_hash"],
                  row["block_time"],
                  false,
                  row["spent_txid"],
                  row["spent_block_height"],
                  row["created_at"],
                  row["updated_at"]
                ]
              )
            )
          end
        end
      end

      def insert_tx_outputs(connection, temp_table)
        result = connection.exec_query(<<~SQL)
          INSERT INTO tx_outputs (
            txid,
            vout,
            address,
            amount_btc,
            block_height,
            block_hash,
            block_time,
            spent,
            spent_txid,
            spent_block_height,
            created_at,
            updated_at
          )
          SELECT
            txid,
            vout,
            address,
            amount_btc,
            block_height,
            block_hash,
            block_time,
            FALSE,
            spent_txid,
            spent_block_height,
            created_at,
            updated_at
          FROM #{temp_table}
          ON CONFLICT (txid, vout) DO NOTHING
          RETURNING id
        SQL

        result.rows.size
      end

      def insert_utxo_outputs(connection, temp_table)
        connection.exec_query(<<~SQL)
          INSERT INTO utxo_outputs (
            txid,
            vout,
            address,
            amount_btc,
            block_height,
            block_hash,
            block_time,
            created_at,
            updated_at
          )
          SELECT
            txid,
            vout,
            address,
            amount_btc,
            block_height,
            block_hash,
            block_time,
            created_at,
            updated_at
          FROM #{temp_table}
          ON CONFLICT (txid, vout) DO NOTHING
          RETURNING address, amount_btc, block_height
        SQL
      end

      def measure_stage(stage, timings = nil)
        started_at = monotonic_ms
        result = yield
        duration_ms = monotonic_ms - started_at

        timings[stage.to_sym] = duration_ms if timings
        @logger.info("[output_flusher_timing] stage=#{stage} duration_ms=#{duration_ms}")

        result
      rescue StandardError => e
        duration_ms = monotonic_ms - started_at
        timings[stage.to_sym] = duration_ms if timings

        @logger.error(
          "[output_flusher_timing] stage_failed=#{stage} " \
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
