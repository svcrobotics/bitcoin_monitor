# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class OperationalSnapshot
      QUEUE_NAME = "tx_outputs_async"

      def self.call(processed_height: nil)
        new(processed_height: processed_height).call
      end

      def initialize(processed_height: nil)
        @processed_height = processed_height&.to_i
      end

      def call
        worker = queue_process
        queue_size = queue_size_for(QUEUE_NAME)
        scheduled_jobs = scheduled_queue_size(QUEUE_NAME)
        table_exists =
          ActiveRecord::Base
            .connection
            .data_source_exists?("layer1_tx_output_syncs")

        configured =
          Config.enabled? ||
          worker[:present] ||
          queue_size.positive? ||
          scheduled_jobs.positive?

        configured ||= table_exists && Layer1TxOutputSync.exists?

        return disabled_snapshot(worker: worker) unless configured

        unless table_exists
          return {
            status: "unavailable",
            enabled: true,
            migration_pending: true,
            worker: worker,
            queue_size: queue_size,
            scheduled_jobs: scheduled_jobs
          }
        end

        pending_scope =
          Layer1TxOutputSync.where(status: "pending")
        processing_scope =
          Layer1TxOutputSync.where(status: "processing")
        failed_scope =
          Layer1TxOutputSync.where(status: "failed")
        selectable_scope =
          Layer1TxOutputSync.where(status: %w[pending processing failed])
        last_synced_height =
          Layer1TxOutputSync.where(status: "synced").maximum(:height)
        stale_scope =
          stale_processing_scope(processing_scope)

        {
          status: projection_status(
            pending_scope: selectable_scope,
            last_synced_height: last_synced_height,
            worker: worker
          ),
          enabled: true,
          worker: worker,
          queue_size: queue_size,
          scheduled_jobs: scheduled_jobs,
          pending_count: pending_scope.count,
          processing_count: processing_scope.count,
          failed_count: failed_scope.count,
          stale_processing_count: stale_scope.count,
          oldest_pending_height: selectable_scope.minimum(:height),
          oldest_processing_height: processing_scope.minimum(:height),
          oldest_processing_age_seconds:
            oldest_processing_age_seconds(processing_scope),
          lock_present: lock_present?,
          job_active: worker[:busy].to_i.positive?,
          recovery: recovery_status,
          next_record_height:
            Layer1::TxOutputsSpentSync::NextRecord.call&.height,
          historical_budget: historical_budget_snapshot,
          last_synced_height: last_synced_height,
          projection_lag_blocks: projection_lag(last_synced_height)
        }
      rescue StandardError => e
        {
          status: "unavailable",
          enabled: true,
          error: "#{e.class}: #{e.message}"
        }
      end

      private

      attr_reader :processed_height

      def disabled_snapshot(worker:)
        {
          status: "disabled",
          enabled: false,
          worker: worker
        }
      end

      def projection_status(pending_scope:, last_synced_height:, worker:)
        failed_count = Layer1TxOutputSync.where(status: "failed").count
        pending_count = pending_scope.count
        stale_count =
          stale_processing_scope(
            Layer1TxOutputSync.where(status: "processing")
          ).count
        lag = projection_lag(last_synced_height).to_i

        return "failed" if failed_count.positive?
        return "waiting" if stale_count.positive? && worker[:busy].to_i.zero?
        return "processing" if worker[:busy].to_i.positive?
        return "pending" if pending_count.positive? || lag.positive?
        return "synced" if last_synced_height.present?

        "idle"
      end

      def projection_lag(last_synced_height)
        return nil unless processed_height && last_synced_height

        [processed_height - last_synced_height.to_i, 0].max
      end

      def queue_process
        require "sidekiq/api"

        matching_processes =
          Sidekiq::ProcessSet.new.select do |candidate|
            Array(candidate["queues"]).include?(QUEUE_NAME)
          end

        active_processes =
          matching_processes.reject do |candidate|
            candidate["quiet"].to_s == "true"
          end

        if active_processes.empty?
          return {
            present: false,
            process_count: 0,
            stopping_process_count: matching_processes.size
          }
        end

        representative =
          active_processes.max_by do |candidate|
            [
              candidate["busy"].to_i,
              candidate["pid"].to_i
            ]
          end

        {
          present: true,
          pid: representative["pid"],
          busy:
            active_processes.sum do |candidate|
              candidate["busy"].to_i
            end,
          concurrency:
            active_processes.sum do |candidate|
              candidate["concurrency"].to_i
            end,
          queues: representative["queues"],
          process_count: active_processes.size,
          stopping_process_count:
            matching_processes.size - active_processes.size
        }
      rescue StandardError => e
        { present: false, error: e.message }
      end

      def queue_size_for(name)
        require "sidekiq/api"

        Sidekiq::Queue.new(name).size
      rescue StandardError
        0
      end

      def scheduled_queue_size(name)
        require "sidekiq/api"

        Sidekiq::ScheduledSet.new.count do |job|
          job.queue.to_s == name.to_s
        end
      rescue StandardError
        0
      end

      def stale_processing_scope(scope)
        scope.where(
          "COALESCE(last_attempt_at, started_at, updated_at) < ?",
          Config.recovery_stale_after_seconds.seconds.ago
        )
      end

      def oldest_processing_age_seconds(scope)
        timestamp =
          scope.minimum(
            Arel.sql("COALESCE(last_attempt_at, started_at, updated_at)")
          )

        return nil unless timestamp

        [(Time.current - timestamp).to_i, 0].max
      end

      def lock_present?
        require "sidekiq/api"

        Sidekiq.redis do |redis|
          value =
            redis.exists?(Layer1::TxOutputsSpentSyncJob::LOCK_KEY)

          value == true || value.to_i.positive?
        end
      rescue StandardError
        false
      end

      def recovery_status
        require "json"
        require "sidekiq/api"

        raw =
          Sidekiq.redis do |redis|
            redis.get(Layer1::TxOutputsSpentSync::Recovery::STATUS_KEY)
          end

        raw.present? ? JSON.parse(raw).with_indifferent_access : {}
      rescue StandardError
        {}
      end

      def historical_budget_snapshot
        snapshot =
          System::PipelineController.snapshot

        {
          layer1_lag:
            snapshot.dig(:layer1, :lag).to_i,
          layer1_lag_budget:
            Layer1::HistoricalWorkConfig.max_layer1_lag_blocks,
          cluster_lag:
            snapshot.dig(:cluster, :lag).to_i,
          cluster_lag_budget:
            Layer1::HistoricalWorkConfig.max_cluster_lag_blocks,
          decision:
            System::PipelineController
              .decision(:tx_outputs_async, current_snapshot: snapshot)
              .slice(:allowed, :state, :reason, :failed_constraints)
        }
      rescue StandardError => error
        { error: "#{error.class}: #{error.message}" }
      end
    end
  end
end
