# frozen_string_literal: true

module Clusters
  module Coverage
    class SingletonRunner
      DEFAULT_BATCH_SIZE = 500
      DEFAULT_MAX_BATCHES = 20
      ADVISORY_LOCK_KEY = 47_312

      def self.call(
        batch_size: DEFAULT_BATCH_SIZE,
        max_batches: DEFAULT_MAX_BATCHES,
        after_id: nil,
        lock: true
      )
        new(
          batch_size: batch_size,
          max_batches: max_batches,
          after_id: after_id,
          lock: lock
        ).call
      end

      def initialize(
        batch_size: DEFAULT_BATCH_SIZE,
        max_batches: DEFAULT_MAX_BATCHES,
        after_id: nil,
        lock: true
      )
        @batch_size =
          [
            batch_size.to_i,
            1
          ].max

        @max_batches =
          [
            max_batches.to_i,
            1
          ].max

        @cursor = after_id&.to_i
        @initial_after_id = @cursor
        @lock = lock == true
        @locked = false

        reset_metrics
      end

      def call
        if lock
          @locked = acquire_lock

          return already_running_result unless locked
        end

        run_batches
      rescue StandardError => error
        error_result(error)
      ensure
        release_lock if lock && locked
      end

      private

      attr_reader(
        :batch_size,
        :max_batches,
        :cursor,
        :initial_after_id,
        :lock,
        :locked,
        :batches,
        :scanned,
        :valid_addresses,
        :invalid_addresses,
        :updated,
        :singleton_clusters_created,
        :ignored_already_clustered,
        :last_address_id
      )

      def reset_metrics
        @batches = 0
        @scanned = 0
        @valid_addresses = 0
        @invalid_addresses = 0
        @updated = 0
        @singleton_clusters_created = 0
        @ignored_already_clustered = 0
        @last_address_id = initial_after_id
      end

      def run_batches
        stopped_reason = "max_batches"

        max_batches.times do
          result =
            Clusters::Coverage::SingletonBuilder.call(
              batch_size: batch_size,
              after_id: cursor
            )

          if result[:scanned].to_i.zero?
            stopped_reason = "empty_batch"
            break
          end

          record_batch(result)
        end

        success_result(stopped_reason)
      end

      def record_batch(result)
        @batches += 1
        @scanned += result[:scanned].to_i
        @valid_addresses += result[:valid_addresses].to_i
        @invalid_addresses += result[:invalid_addresses].to_i
        @updated += result[:updated].to_i
        @singleton_clusters_created +=
          result[:singleton_clusters_created].to_i
        @ignored_already_clustered +=
          result[:ignored_already_clustered].to_i

        @last_address_id =
          result[:last_address_id]

        @cursor =
          result[:last_address_id]
      end

      def success_result(stopped_reason)
        metrics.merge(
          ok: true,
          locked: lock ? locked : nil,
          stopped_reason: stopped_reason
        )
      end

      def error_result(error)
        metrics.merge(
          ok: false,
          locked: lock ? locked : nil,
          stopped_reason: "error",
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def already_running_result
        metrics.merge(
          ok: false,
          locked: false,
          stopped_reason: "already_running"
        )
      end

      def metrics
        {
          batches: batches,
          scanned: scanned,
          valid_addresses: valid_addresses,
          invalid_addresses: invalid_addresses,
          updated: updated,
          singleton_clusters_created: singleton_clusters_created,
          ignored_already_clustered: ignored_already_clustered,
          initial_after_id: initial_after_id,
          last_address_id: last_address_id
        }
      end

      def acquire_lock
        value =
          ActiveRecord::Base
            .connection
            .select_value(
              "SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})"
            )

        value == true || value == "t"
      end

      def release_lock
        ActiveRecord::Base
          .connection
          .select_value(
            "SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})"
          )
      end
    end
  end
end
