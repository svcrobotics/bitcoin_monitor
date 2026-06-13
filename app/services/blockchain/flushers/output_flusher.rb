# frozen_string_literal: true

require "csv"
require "securerandom"

module Blockchain
  module Flushers
    class OutputFlusher
      KEY = Blockchain::Buffers::OutputBuffer::KEY
      BATCH_SIZE = ENV.fetch("OUTPUT_FLUSH_BATCH_SIZE", 2_000).to_i

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
        rows = pop_batch
        return { ok: true, flushed: 0, inserted: 0, skipped: 0 } if rows.empty?

        inserted = copy_insert(rows)

        @logger.info(
          "[output_flusher] flushed=#{rows.size} inserted=#{inserted} skipped_existing=#{rows.size - inserted}"
        )

        {
          ok: true,
          flushed: rows.size,
          inserted: inserted,
          skipped: rows.size - inserted
        }
      end

      private

      def pop_batch
        payloads = @redis.lpop(KEY, BATCH_SIZE)
        Array(payloads).map { |payload| JSON.parse(payload) }
      end

      def copy_insert(rows)
        temp_table = "tmp_tx_outputs_#{SecureRandom.hex(8)}"

        connection = ActiveRecord::Base.connection
        raw = connection.raw_connection

        inserted = 0

        connection.transaction do
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

          inserted_rows = connection.exec_query(<<~SQL)
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

          inserted = inserted_rows.rows.size

          if inserted.positive?
            inserted_temp = "tmp_inserted_outputs_#{SecureRandom.hex(8)}"

            connection.execute(<<~SQL)
              CREATE TEMP TABLE #{inserted_temp} (
                address text,
                amount_btc numeric,
                block_height integer
              ) ON COMMIT DROP
            SQL

            raw.copy_data("COPY #{inserted_temp} (address, amount_btc, block_height) FROM STDIN WITH (FORMAT csv)") do
              inserted_rows.rows.each do |address, amount_btc, block_height|
                raw.put_copy_data(
                  CSV.generate_line([address, amount_btc, block_height])
                )
              end
            end

            connection.execute(<<~SQL)
              INSERT INTO addresses (
                address,
                total_received_sats,
                first_seen_height,
                last_seen_height,
                tx_count,
                created_at,
                updated_at
              )
              SELECT
                address,
                SUM((amount_btc * 100000000)::bigint) AS total_received_sats,
                MIN(block_height) AS first_seen_height,
                MAX(block_height) AS last_seen_height,
                COUNT(*) AS tx_count,
                NOW(),
                NOW()
              FROM #{inserted_temp}
              WHERE address IS NOT NULL
                AND address != ''
              GROUP BY address
              ON CONFLICT (address) DO UPDATE SET
                total_received_sats = COALESCE(addresses.total_received_sats, 0) + EXCLUDED.total_received_sats,
                first_seen_height = LEAST(addresses.first_seen_height, EXCLUDED.first_seen_height),
                last_seen_height = GREATEST(addresses.last_seen_height, EXCLUDED.last_seen_height),
                tx_count = COALESCE(addresses.tx_count, 0) + EXCLUDED.tx_count,
                updated_at = NOW()
            SQL

            Clusters::EnsureAddressClusters.call(
              addresses: inserted_rows.rows.map { |row| row[0] }
            )
          end
        end

        inserted
      end
    end
  end
end