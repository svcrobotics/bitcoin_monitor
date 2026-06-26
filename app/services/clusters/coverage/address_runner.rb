# frozen_string_literal: true

module Clusters
  module Coverage
    class AddressRunner
      DEFAULT_BATCH_SIZE = 500
      DEFAULT_MAX_BATCHES = 10
      ADVISORY_LOCK_KEY = 47_313

      def self.call(
        batch_size: DEFAULT_BATCH_SIZE,
        max_batches: DEFAULT_MAX_BATCHES,
        reconcile: false,
        lock: true
      )
        new(
          batch_size: batch_size,
          max_batches: max_batches,
          reconcile: reconcile,
          lock: lock
        ).call
      end

      def initialize(
        batch_size: DEFAULT_BATCH_SIZE,
        max_batches: DEFAULT_MAX_BATCHES,
        reconcile: false,
        lock: true
      )
        @batch_size = [batch_size.to_i, 1].max
        @max_batches = [max_batches.to_i, 1].max
        @reconcile = reconcile == true
        @lock = lock == true
        @locked = false

        reset_metrics
      end

      def call
        started_at = monotonic_seconds

        result = nil

        begin
          if lock
            @locked = acquire_lock
            result = already_running_result unless locked
          end

          result ||= run_with_cursor
        rescue StandardError => error
          record_failure(error)
          result = error_result(error)
        ensure
          release_lock if lock && locked
        end

        result.merge(duration_metrics(started_at))
      end

      private

      attr_reader(
        :batch_size,
        :max_batches,
        :reconcile,
        :lock,
        :locked,
        :cursor_record,
        :cursor,
        :high_watermark,
        :batches,
        :scanned,
        :valid_addresses,
        :invalid_addresses,
        :already_clustered,
        :skipped_pending_cluster_inputs,
        :updated,
        :singleton_clusters_created,
        :ignored_already_clustered,
        :first_address_id,
        :last_address_id
      )

      def reset_metrics
        @batches = 0
        @scanned = 0
        @valid_addresses = 0
        @invalid_addresses = 0
        @already_clustered = 0
        @skipped_pending_cluster_inputs = 0
        @updated = 0
        @singleton_clusters_created = 0
        @ignored_already_clustered = 0
        @first_address_id = nil
        @last_address_id = nil
      end

      def run_with_cursor
        ClusterCoverageBlock.transaction do
          @cursor_record = AddressCursor.record
          prepare_cursor!
          cursor_record.save!
        end

        stopped_reason = "max_batches"

        max_batches.times do
          result =
            AddressPage.call(
              after_id: cursor,
              high_watermark: high_watermark,
              batch_size: batch_size,
              reconcile: reconcile
            )

          if result[:scanned].to_i.zero?
            stopped_reason = "empty_batch"
            break
          end

          record_batch(result)
          persist_cursor_page!(result)
        end

        finalize_cursor!(stopped_reason)
        success_result(stopped_reason)
      end

      def prepare_cursor!
        @high_watermark =
          if reconcile
            cursor_record.after_tx_output_id.to_i
          else
            Address.maximum(:id).to_i
          end

        @cursor =
          if reconcile
            reconciliation_after_id
          else
            cursor_record.after_tx_output_id.to_i
          end

        cursor_record.status = "processing"
        cursor_record.started_at ||= Time.current
        cursor_record.completed_at = nil
        cursor_record.last_error = nil
        cursor_record.max_tx_output_id = high_watermark
        cursor_record.attempts = cursor_record.attempts.to_i + 1
        cursor_record.metadata =
          cursor_record
            .metadata
            .to_h
            .merge(
              "source" => AddressCursor::SOURCE,
              "profile_version" => AddressCursor::PROFILE_VERSION,
              "cursor_source" => "addresses",
              "run_mode" => reconcile ? "reconciliation" : "cursor",
              "high_watermark_address_id" => high_watermark.to_s,
              "started_at" => Time.current.iso8601(6)
            )
      end

      def reconciliation_after_id
        cursor_record
          .metadata
          .to_h
          .fetch(
            "reconciliation_after_address_id",
            reconciliation_floor_id.to_s
          )
          .to_i
      end

      def reconciliation_floor_id
        cursor_record
          .metadata
          .to_h
          .fetch("seeded_from_bootstrap_address_id", "0")
          .to_i
      end

      def record_batch(result)
        @batches += 1
        @scanned += result[:scanned].to_i
        @valid_addresses += result[:valid_addresses].to_i
        @invalid_addresses += result[:invalid_addresses].to_i
        @already_clustered += result[:already_clustered].to_i
        @skipped_pending_cluster_inputs +=
          result[:skipped_pending_cluster_inputs].to_i
        @updated += result[:updated].to_i
        @singleton_clusters_created +=
          result[:singleton_clusters_created].to_i
        @ignored_already_clustered +=
          result[:ignored_already_clustered].to_i
        @first_address_id ||= result[:first_address_id]
        @last_address_id = result[:last_address_id]
        @cursor = result[:last_address_id].to_i
      end

      def persist_cursor_page!(result)
        ClusterCoverageBlock.transaction do
          record =
            ClusterCoverageBlock
              .lock
              .find(cursor_record.id)

          record.after_tx_output_id = cursor unless reconcile
          record.processed_outputs_count =
            record.processed_outputs_count.to_i +
            result[:scanned].to_i
          record.processed_address_outputs_count =
            record.processed_address_outputs_count.to_i +
            result[:updated].to_i
          record.singleton_clusters_created_count =
            record.singleton_clusters_created_count.to_i +
            result[:singleton_clusters_created].to_i
          record.pages_processed =
            record.pages_processed.to_i + 1
          record.metadata =
            page_metadata(record)

          record.save!
          @cursor_record = record
        end
      end

      def page_metadata(record)
        metadata =
          record
            .metadata
            .to_h
            .merge(
              "last_processed_address_id" =>
                (reconcile ? record.after_tx_output_id : cursor).to_s,
              "high_watermark_address_id" =>
                high_watermark.to_s,
              "last_page_last_address_id" =>
                cursor.to_s,
              "last_page_completed_at" =>
                Time.current.iso8601(6)
            )

        if reconcile
          metadata["reconciliation_after_address_id"] =
            next_reconciliation_after_id.to_s
        end

        metadata
      end

      def next_reconciliation_after_id
        return 0 if cursor >= high_watermark

        cursor
      end

      def finalize_cursor!(stopped_reason)
        ClusterCoverageBlock.transaction do
          record =
            ClusterCoverageBlock
              .lock
              .find(cursor_record.id)

          record.status =
            stopped_reason == "empty_batch" ? "completed" : "pending"
          record.completed_at =
            Time.current if stopped_reason == "empty_batch"
          record.last_error = nil
          record.metadata =
            record
              .metadata
              .to_h
              .merge(
                "stopped_reason" => stopped_reason,
                "completed_at" => Time.current.iso8601(6)
              )

          if reconcile && stopped_reason == "empty_batch"
            record.metadata =
              record
                .metadata
                .to_h
                .merge(
                  # Le passage est terminé. Le prochain cycle repart
                  # du début afin de revoir les adresses précédemment
                  # réservées à Cluster strict.
                  "reconciliation_after_address_id" =>
                    reconciliation_floor_id.to_s
                )
          end

          record.save!
          @cursor_record = record
        end
      end

      def success_result(stopped_reason)
        metrics.merge(
          ok: true,
          locked: lock ? locked : nil,
          reconcile: reconcile,
          high_watermark: high_watermark,
          stopped_reason: stopped_reason
        )
      end

      def record_failure(error)
        return unless cursor_record&.persisted?

        cursor_record.update!(
          status: "failed",
          last_error: "#{error.class}: #{error.message}".first(2_000),
          metadata:
            cursor_record
              .metadata
              .to_h
              .merge(
                "failed_at" => Time.current.iso8601(6)
              )
        )
      end

      def error_result(error)
        metrics.merge(
          ok: false,
          locked: lock ? locked : nil,
          reconcile: reconcile,
          high_watermark: high_watermark,
          stopped_reason: "error",
          error_class: error.class.name,
          error_message: error.message
        )
      end

      def already_running_result
        metrics.merge(
          ok: false,
          locked: false,
          reconcile: reconcile,
          stopped_reason: "already_running"
        )
      end

      def metrics
        {
          batches: batches,
          scanned: scanned,
          valid_addresses: valid_addresses,
          invalid_addresses: invalid_addresses,
          already_clustered: already_clustered,
          skipped_pending_cluster_inputs:
            skipped_pending_cluster_inputs,
          updated: updated,
          singleton_clusters_created: singleton_clusters_created,
          ignored_already_clustered: ignored_already_clustered,
          first_address_id: first_address_id,
          last_address_id: last_address_id
        }
      end

      def duration_metrics(started_at)
        duration_seconds = monotonic_seconds - started_at

        {
          duration_ms: (duration_seconds * 1_000).round,
          duration_seconds: duration_seconds.round(3),
          addresses_per_second: addresses_per_second(duration_seconds)
        }
      end

      def addresses_per_second(duration_seconds)
        return 0.0 unless duration_seconds.positive?

        (scanned / duration_seconds).round(2)
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

      def monotonic_seconds
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
