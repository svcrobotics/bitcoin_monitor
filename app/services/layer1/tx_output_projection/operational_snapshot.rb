# frozen_string_literal: true

module Layer1
  module TxOutputProjection
    class OperationalSnapshot
      QUEUE_NAME = "tx_output_projection"

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
            .data_source_exists?("layer1_tx_output_projection_blocks")

        configured =
          Config.enabled? ||
          worker[:present] ||
          queue_size.positive? ||
          scheduled_jobs.positive?

        configured ||= table_exists && Layer1TxOutputProjectionBlock.exists?

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
          Layer1TxOutputProjectionBlock.where(status: "pending")
        processing_scope =
          Layer1TxOutputProjectionBlock.where(status: "processing")
        failed_scope =
          Layer1TxOutputProjectionBlock.failed
        selectable_scope =
          Layer1TxOutputProjectionBlock.where(status: %w[pending processing failed])
        last_projected_height =
          Layer1TxOutputProjectionBlock.projected.maximum(:height)
        stale_scope =
          stale_processing_scope(processing_scope)

        {
          status: projection_status(
            pending_scope: selectable_scope,
            last_projected_height: last_projected_height,
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
          partially_written_processing_count:
            partially_written_processing_count(processing_scope),
          lock_present: lock_present?,
          job_active: worker[:busy].to_i.positive?,
          recovery: recovery_status,
          next_record_height:
            Layer1::TxOutputProjection::NextRecord.call&.height,
          historical_budget: historical_budget_snapshot,
          last_projected_height: last_projected_height,
          projection_lag_blocks: projection_lag(last_projected_height)
        }
      rescue StandardError => error
        {
          status: "unavailable",
          enabled: true,
          error: "#{error.class}: #{error.message}"
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

      def projection_status(pending_scope:, last_projected_height:, worker:)
        failed_count = Layer1TxOutputProjectionBlock.failed.count
        pending_count = pending_scope.count
        stale_count =
          stale_processing_scope(
            Layer1TxOutputProjectionBlock.where(status: "processing")
          ).count
        lag = projection_lag(last_projected_height).to_i

        return "failed" if failed_count.positive?
        return "waiting" if stale_count.positive? && worker[:busy].to_i.zero?
        return "processing" if worker[:busy].to_i.positive?
        return "pending" if pending_count.positive? || lag.positive?
        return "synced" if last_projected_height.present?

        "idle"
      end

      def projection_lag(last_projected_height)
        return nil unless processed_height && last_projected_height

        [processed_height - last_projected_height.to_i, 0].max
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
      rescue StandardError => error
        { present: false, error: error.message }
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

      def partially_written_processing_count(scope)
        scope.count do |record|
          expected = record.expected_outputs_count.to_i
          actual =
            TxOutput.where(block_height: record.height).count

          actual.positive? && actual < expected
        end
      end

      def lock_present?
        require "sidekiq/api"

        Sidekiq.redis do |redis|
          value =
            redis.exists?(Layer1::TxOutputProjectionJob::LOCK_KEY)

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
            redis.get(Layer1::TxOutputProjection::Recovery::STATUS_KEY)
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
              .decision(:tx_output_projection, current_snapshot: snapshot)
              .slice(:allowed, :state, :reason, :failed_constraints)
        }
      rescue StandardError => error
        { error: "#{error.class}: #{error.message}" }
      end
    end
  end
end
