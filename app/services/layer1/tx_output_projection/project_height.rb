# frozen_string_literal: true

require "csv"
require "securerandom"

module Layer1
  module TxOutputProjection
    class ProjectHeight
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

      def self.call(
        projection_block:,
        rpc: BitcoinRpc.new,
        batch_size: Config.batch_size,
        logger: Rails.logger
      )
        new(
          projection_block: projection_block,
          rpc: rpc,
          batch_size: batch_size,
          logger: logger
        ).call
      end

      def initialize(projection_block:, rpc:, batch_size:, logger:)
        @projection_block = projection_block
        @height = projection_block.height.to_i
        @block_hash = projection_block.block_hash.to_s
        @rpc = rpc
        @batch_size = [batch_size.to_i, 1].max
        @logger = logger
      end

      def call
        started_at = monotonic_ms
        mark_processing!

        block = read_block
        rows = build_rows(block)
        projected_outputs_count = rows.size
        projected_outputs_value_btc = rows.sum { |row| row.fetch(:amount_btc) }

        ensure_expected_facts!(
          projected_outputs_count: projected_outputs_count,
          projected_outputs_value_btc: projected_outputs_value_btc
        )

        rows_inserted = insert_rows(rows)
        rows_skipped = projected_outputs_count - rows_inserted
        duration_ms = monotonic_ms - started_at

        @projection_block.update!(
          status: "projected",
          projected_outputs_count: projected_outputs_count,
          projected_outputs_value_btc: projected_outputs_value_btc,
          rows_inserted: rows_inserted,
          rows_skipped: rows_skipped,
          attempts: 0,
          duration_ms: @projection_block.duration_ms.to_i + duration_ms,
          completed_at: Time.current,
          last_error: nil,
          metadata: projection_metadata(block)
        )

        result = {
          ok: true,
          height: @height,
          status: "projected",
          expected_outputs_count: @projection_block.expected_outputs_count,
          expected_outputs_value_btc: @projection_block.expected_outputs_value_btc,
          projected_outputs_count: projected_outputs_count,
          projected_outputs_value_btc: projected_outputs_value_btc,
          rows_inserted: rows_inserted,
          rows_skipped: rows_skipped,
          duration_ms: duration_ms
        }

        @logger.info("[tx_output_projection] #{result.inspect}")
        result
      rescue StandardError => e
        duration_ms = monotonic_ms - started_at

        @projection_block.update_columns(
          status: "failed",
          attempts: @projection_block.attempts.to_i + 1,
          duration_ms: @projection_block.duration_ms.to_i + duration_ms,
          last_attempt_at: Time.current,
          last_error: "#{e.class}: #{e.message}".first(2_000),
          updated_at: Time.current
        )

        @logger.error(
          "[tx_output_projection] failed height=#{@height} " \
          "duration_ms=#{duration_ms} error=#{e.class}: #{e.message}"
        )

        raise
      end

      private

      def mark_processing!
        @projection_block.update!(
          status: "processing",
          started_at: @projection_block.started_at || Time.current,
          last_attempt_at: Time.current,
          completed_at: nil,
          last_error: nil
        )
      end

      def read_block
        actual_hash = @rpc.getblockhash(@height).to_s

        unless actual_hash == @block_hash
          raise(
            "block hash mismatch height=#{@height} " \
            "expected=#{@block_hash} actual=#{actual_hash}"
          )
        end

        block = @rpc.getblock(@block_hash, 2)
        block_hash = block.fetch("hash").to_s

        unless block_hash == @block_hash
          raise(
            "block payload hash mismatch height=#{@height} " \
            "expected=#{@block_hash} actual=#{block_hash}"
          )
        end

        block
      end

      def build_rows(block)
        now = Time.current
        block_time = normalize_time(block["time"])
        txs = Array(block.fetch("tx"))

        txs.flat_map do |tx|
          txid = tx.fetch("txid").to_s

          Array(tx["vout"]).each_with_index.map do |output, fallback_vout|
            {
              txid: txid,
              vout: output.fetch("n", fallback_vout).to_i,
              address: extract_address(output),
              amount_btc: BigDecimal(output.fetch("value").to_s),
              block_height: @height,
              block_hash: @block_hash,
              block_time: block_time,
              spent: false,
              spent_txid: nil,
              spent_block_height: nil,
              created_at: now,
              updated_at: now
            }
          end
        end
      end

      def ensure_expected_facts!(projected_outputs_count:, projected_outputs_value_btc:)
        expected_count = @projection_block.expected_outputs_count.to_i
        expected_value = BigDecimal(@projection_block.expected_outputs_value_btc.to_s)

        return if expected_count == projected_outputs_count &&
                  expected_value == projected_outputs_value_btc

        raise(
          "projected facts mismatch height=#{@height} " \
          "expected_count=#{expected_count} projected_count=#{projected_outputs_count} " \
          "expected_value=#{expected_value.to_s('F')} " \
          "projected_value=#{projected_outputs_value_btc.to_s('F')}"
        )
      end

      def insert_rows(rows)
        return 0 if rows.empty?

        rows.each_slice(@batch_size).sum do |slice|
          copy_insert(slice)
        end
      end

      def copy_insert(rows)
        temp_table = "tmp_tx_output_projection_#{SecureRandom.hex(8)}"
        connection = ActiveRecord::Base.connection
        raw = connection.raw_connection

        connection.transaction do
          create_temp_table(connection, temp_table)
          copy_rows(raw, temp_table, rows)
          insert_tx_outputs(connection, temp_table)
        end
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
                COLUMNS.map { |column| row.fetch(column.to_sym) }
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

      def extract_address(output)
        script = output["scriptPubKey"] || {}

        return script["address"] if script["address"].present?
        return script["addresses"].first if script["addresses"].present?

        nil
      end

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return Time.at(value).in_time_zone if value.present?

        nil
      end

      def projection_metadata(block)
        {
          source: "bitcoin_core",
          block_tx_count: Array(block["tx"]).size,
          batch_size: @batch_size
        }
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end
