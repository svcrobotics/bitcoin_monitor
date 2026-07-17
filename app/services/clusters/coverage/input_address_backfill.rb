# frozen_string_literal: true

module Clusters
  module Coverage
    class InputAddressBackfill
      DEFAULT_BATCH_SIZE = 1_000
      DEFAULT_WINDOW_BLOCKS = 100
      ADVISORY_LOCK_KEY = 47_313

      def self.call(
        from_height: nil,
        to_height: nil,
        batch_size: DEFAULT_BATCH_SIZE,
        window_blocks: DEFAULT_WINDOW_BLOCKS,
        lock: true
      )
        new(
          from_height: from_height,
          to_height: to_height,
          batch_size: batch_size,
          window_blocks: window_blocks,
          lock: lock
        ).call
      end

      def initialize(
        from_height:,
        to_height:,
        batch_size:,
        window_blocks:,
        lock:
      )
        @requested_from_height =
          from_height&.to_i

        @requested_to_height =
          to_height&.to_i

        @batch_size =
          [batch_size.to_i, 1].max

        @window_blocks =
          [window_blocks.to_i, 1].max

        @lock = lock
        @locked = false
      end

      def call
        started_at =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )

        if lock
          @locked = acquire_lock

          return locked_result(started_at) unless locked
        end

        run(started_at)
      rescue StandardError => error
        {
          ok: false,
          error_class: error.class.name,
          error_message: error.message
        }
      ensure
        release_lock if lock && locked
      end

      private

      attr_reader(
        :requested_from_height,
        :requested_to_height,
        :batch_size,
        :window_blocks,
        :lock,
        :locked
      )

      def run(started_at)
        cluster_tip =
          ClusterProcessedBlock
            .where(status: "processed")
            .maximum(:height)
            .to_i

        raise "Cluster processed tip unavailable" if cluster_tip.zero?

        to_height =
          [
            requested_to_height || cluster_tip,
            cluster_tip
          ].min

        from_height =
          requested_from_height ||
          [
            to_height - window_blocks + 1,
            0
          ].max

        raise(
          ArgumentError,
          "from_height exceeds to_height"
        ) if from_height > to_height

        cursor = nil
        scanned = 0
        valid = 0
        invalid = 0
        inserted = 0
        batches = 0

        loop do
          rows =
            missing_address_rows(
              from_height: from_height,
              to_height: to_height,
              after_address: cursor
            )

          break if rows.empty?

          batches += 1
          scanned += rows.size

          valid_rows =
            rows.select do |row|
              BitcoinAddressValidator
                .valid_bitcoin_address?(
                  row.fetch("address")
                )
            end

          valid += valid_rows.size
          invalid += rows.size - valid_rows.size

          inserted += upsert_addresses(valid_rows)

          cursor =
            rows
              .last
              .fetch("address")
        end

        duration_seconds =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at

        {
          ok: true,
          locked: locked,
          cluster_tip: cluster_tip,
          from_height: from_height,
          to_height: to_height,
          batches: batches,
          scanned_missing_addresses: scanned,
          valid_addresses: valid,
          invalid_addresses: invalid,
          addresses_upserted: inserted,
          stopped_reason: "empty_batch",
          duration_ms:
            (duration_seconds * 1_000).round,
          duration_seconds:
            duration_seconds.round(3)
        }
      end

      def missing_address_rows(
        from_height:,
        to_height:,
        after_address:
      )
        connection =
          ApplicationRecord.connection

        cursor_condition =
          if after_address.present?
            "AND cluster_inputs.address > " \
              "#{connection.quote(after_address)}"
          else
            ""
          end

        sql = <<~SQL
          SELECT
            cluster_inputs.address AS address,

            MIN(
              COALESCE(
                cluster_inputs.block_height,
                cluster_inputs.spent_block_height
              )
            ) AS first_seen_height,

            MAX(
              COALESCE(
                cluster_inputs.spent_block_height,
                cluster_inputs.block_height
              )
            ) AS last_seen_height,

            COUNT(
              DISTINCT cluster_inputs.spent_txid
            ) AS tx_count

          FROM cluster_inputs

          LEFT JOIN addresses
            ON addresses.address =
               cluster_inputs.address

          WHERE
            cluster_inputs.spent_block_height
              BETWEEN #{from_height.to_i}
                  AND #{to_height.to_i}

            AND cluster_inputs.address
                IS NOT NULL

            AND cluster_inputs.address <> ''

            AND addresses.id IS NULL

            #{cursor_condition}

          GROUP BY
            cluster_inputs.address

          ORDER BY
            cluster_inputs.address ASC

          LIMIT #{batch_size}
        SQL

        connection
          .select_all(sql)
          .to_a
      end

      def upsert_addresses(rows)
        return 0 if rows.empty?

        now = Time.current

        payload =
          rows.map do |row|
            {
              address:
                row.fetch("address"),

              first_seen_height:
                row["first_seen_height"]&.to_i,

              last_seen_height:
                row["last_seen_height"]&.to_i,

              tx_count:
                [
                  row["tx_count"].to_i,
                  1
                ].max,

              created_at: now,
              updated_at: now
            }
          end

        Address.upsert_all(
          payload,
          unique_by:
            :index_addresses_on_address,

          on_duplicate:
            Arel.sql(
              "first_seen_height = " \
              "LEAST(" \
                "addresses.first_seen_height, " \
                "EXCLUDED.first_seen_height" \
              "), " \
              "last_seen_height = " \
              "GREATEST(" \
                "addresses.last_seen_height, " \
                "EXCLUDED.last_seen_height" \
              "), " \
              "updated_at = EXCLUDED.updated_at"
            )
        )

        payload.size
      end

      def acquire_lock
        value =
          ApplicationRecord
            .connection
            .select_value(
              "SELECT pg_try_advisory_lock(" \
              "#{ADVISORY_LOCK_KEY})"
            )

        value == true || value == "t"
      end

      def release_lock
        ApplicationRecord
          .connection
          .select_value(
            "SELECT pg_advisory_unlock(" \
            "#{ADVISORY_LOCK_KEY})"
          )
      end

      def locked_result(started_at)
        duration =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at

        {
          ok: false,
          locked: false,
          stopped_reason: "lock_unavailable",
          duration_ms:
            (duration * 1_000).round
        }
      end
    end
  end
end
