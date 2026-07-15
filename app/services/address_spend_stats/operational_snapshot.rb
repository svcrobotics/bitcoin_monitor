# frozen_string_literal: true

module AddressSpendStats
  class OperationalSnapshot
    QUEUE_NAME =
      "actor_profile_strict"

    RECENT_CHECKPOINTS_LIMIT = 5

    def self.call
      new.call
    end

    def initialize(
      runtime: nil,
      table_checker: nil
    )
      @runtime_override = runtime
      @table_checker = table_checker
    end

    def call
      runtime =
        runtime_snapshot

      unless tables_available?
        return unavailable_snapshot(
          runtime: runtime,
          migration_pending: true
        )
      end

      cluster_floor =
        cluster_scope.minimum(:height)

      cluster_tip =
        cluster_scope.maximum(:height)

      projection_tip =
        completed_scope.maximum(:height)

      next_record =
        AddressSpendStats::
          NextRecord.call

      next_record_height =
        next_record&.height&.to_i

      failed =
        failed_checkpoint

      stale_processing =
        stale_processing_checkpoint

      lag =
        projection_lag(
          cluster_floor:
            cluster_floor,
          cluster_tip:
            cluster_tip,
          projection_tip:
            projection_tip
        )

      caught_up =
        cluster_tip.present? &&
        projection_tip.present? &&
        projection_tip.to_i >=
          cluster_tip.to_i &&
        next_record_height.nil?

      issues =
        issues_for(
          cluster_tip:
            cluster_tip,
          projection_tip:
            projection_tip,
          next_record_height:
            next_record_height,
          failed:
            failed,
          stale_processing:
            stale_processing,
          runtime:
            runtime
        )

      {
        module:
          "address_spend_projection",

        source:
          "address_spend_operational_snapshot",

        generated_at:
          Time.current,

        available:
          true,

        status:
          status_for(
            cluster_tip:
              cluster_tip,
            lag:
              lag,
            caught_up:
              caught_up,
            next_record_height:
              next_record_height,
            issues:
              issues
          ),

        sync: {
          cluster_floor:
            cluster_floor&.to_i,

          cluster_tip:
            cluster_tip&.to_i,

          projection_tip:
            projection_tip&.to_i,

          lag:
            lag,

          next_record_height:
            next_record_height,

          caught_up_to_cluster:
            caught_up
        },

        activity: {
          processing_height:
            processing_height,

          stale_processing:
            stale_processing.present?,

          last_completed_at:
            completed_scope
              .maximum(
                :completed_at
              )
        },

        latest_checkpoint:
          latest_checkpoint,

        failed_checkpoint:
          failed,

        stale_processing_checkpoint:
          stale_processing,

        recent_checkpoints:
          recent_checkpoints,

        automation:
          runtime.merge(
            queue_name:
              QUEUE_NAME
          ),

        issues:
          issues
      }
    rescue StandardError => error
      unavailable_snapshot(
        runtime:
          safe_runtime_snapshot,
        error:
          error
      )
    end

    private

    attr_reader(
      :runtime_override,
      :table_checker
    )

    def cluster_scope
      ClusterProcessedBlock.where(
        status: "processed"
      )
    end

    def completed_scope
      AddressSpendProjectionBlock
        .completed
    end

    def tables_available?
      if table_checker.respond_to?(
        :call
      )
        return table_checker.call ==
          true
      end

      connection =
        ApplicationRecord.connection

      connection.data_source_exists?(
        "address_spend_stats"
      ) &&
        connection.data_source_exists?(
          "address_spend_projection_blocks"
        )
    end

    def projection_lag(
      cluster_floor:,
      cluster_tip:,
      projection_tip:
    )
      return nil unless
        cluster_tip

      if projection_tip
        return [
          cluster_tip.to_i -
            projection_tip.to_i,
          0
        ].max
      end

      return 0 unless
        cluster_floor

      [
        cluster_tip.to_i -
          cluster_floor.to_i +
          1,
        0
      ].max
    end

    def status_for(
      cluster_tip:,
      lag:,
      caught_up:,
      next_record_height:,
      issues:
    )
      return "warning" if
        issues.any?

      return "waiting" unless
        cluster_tip

      return "healthy" if
        caught_up

      return "waiting" if
        next_record_height.present? ||
        lag.to_i.positive?

      "waiting"
    end

    def issues_for(
      cluster_tip:,
      projection_tip:,
      next_record_height:,
      failed:,
      stale_processing:,
      runtime:
    )
      issues = []

      if projection_tip &&
         cluster_tip &&
         projection_tip.to_i >
           cluster_tip.to_i
        issues <<
          "projection_tip_above_cluster"
      end

      issues <<
        "failed_checkpoint" if
          failed.present?

      issues <<
        "stale_processing_checkpoint" if
          stale_processing.present?

      if next_record_height &&
         projection_tip &&
         next_record_height.to_i <=
           projection_tip.to_i
        issues <<
          "checkpoint_replay_required"
      end

      issues <<
        "dead_jobs_present" if
          runtime[:dead_jobs]
            .to_i
            .positive?

      issues.uniq
    end

    def failed_checkpoint
      row =
        AddressSpendProjectionBlock
          .failed
          .order(
            updated_at: :desc
          )
          .pick(
            :height,
            :attempts,
            :error_message,
            :updated_at
          )

      return nil unless row

      {
        height:
          row[0].to_i,
        attempts:
          row[1].to_i,
        error_message:
          row[2],
        updated_at:
          row[3]
      }
    end

    def stale_processing_checkpoint
      stale_before =
        AddressSpendStats::Config
          .processing_stale_after_seconds
          .seconds
          .ago

      row =
        AddressSpendProjectionBlock
          .processing
          .where(
            "processing_started_at "             "IS NULL OR "             "processing_started_at < ?",
            stale_before
          )
          .order(:height)
          .pick(
            :height,
            :attempts,
            :processing_started_at,
            :updated_at
          )

      return nil unless row

      {
        height:
          row[0].to_i,
        attempts:
          row[1].to_i,
        processing_started_at:
          row[2],
        updated_at:
          row[3]
      }
    end

    def processing_height
      AddressSpendProjectionBlock
        .processing
        .minimum(:height)
        &.to_i
    end

    def latest_checkpoint
      row =
        AddressSpendProjectionBlock
          .order(height: :desc)
          .pick(
            :height,
            :block_hash,
            :status,
            :input_count,
            :address_count,
            :total_sent_sats,
            :attempts,
            :completed_at,
            :updated_at
          )

      return nil unless row

      {
        height:
          row[0].to_i,
        block_hash:
          row[1],
        status:
          row[2],
        input_count:
          row[3].to_i,
        address_count:
          row[4].to_i,
        total_sent_sats:
          row[5].to_i,
        attempts:
          row[6].to_i,
        completed_at:
          row[7],
        updated_at:
          row[8]
      }
    end

    def recent_checkpoints
      AddressSpendProjectionBlock
        .order(height: :desc)
        .limit(
          RECENT_CHECKPOINTS_LIMIT
        )
        .pluck(
          :height,
          :status,
          :input_count,
          :address_count,
          :total_sent_sats,
          :attempts,
          :completed_at
        )
        .map do |row|
          {
            height:
              row[0].to_i,
            status:
              row[1],
            input_count:
              row[2].to_i,
            address_count:
              row[3].to_i,
            total_sent_sats:
              row[4].to_i,
            attempts:
              row[5].to_i,
            completed_at:
              row[6]
          }
        end
    end

    def runtime_snapshot
      if runtime_override.respond_to?(
        :call
      )
        return runtime_override
          .call
          .deep_symbolize_keys
      end

      if runtime_override.is_a?(
        Hash
      )
        return runtime_override
          .deep_symbolize_keys
      end

      require "sidekiq/api"

      processes =
        Sidekiq::ProcessSet
          .new
          .select do |process|
            Array(
              process["queues"]
            ).include?(
              QUEUE_NAME
            )
          end

      queue_size =
        Sidekiq::Queue
          .new(
            QUEUE_NAME
          )
          .size

      scheduled_jobs =
        Sidekiq::ScheduledSet
          .new
          .count do |job|
            job.queue.to_s ==
              QUEUE_NAME
          end

      retry_jobs =
        Sidekiq::RetrySet
          .new
          .count do |job|
            job.queue.to_s ==
              QUEUE_NAME
          end

      dead_jobs =
        Sidekiq::DeadSet
          .new
          .count do |job|
            job.queue.to_s ==
              QUEUE_NAME
          end

      {
        configured:
          processes.any? ||
          queue_size.positive? ||
          scheduled_jobs.positive? ||
          retry_jobs.positive? ||
          dead_jobs.positive?,

        process_present:
          processes.any?,

        process_count:
          processes.size,

        busy_workers:
          processes.sum do |process|
            process["busy"].to_i
          end,

        queue_size:
          queue_size,

        scheduled_jobs:
          scheduled_jobs,

        retry_jobs:
          retry_jobs,

        dead_jobs:
          dead_jobs
      }
    rescue StandardError => error
      {
        configured:
          false,
        process_present:
          false,
        process_count:
          0,
        busy_workers:
          0,
        queue_size:
          0,
        scheduled_jobs:
          0,
        retry_jobs:
          0,
        dead_jobs:
          0,
        error:
          "#{error.class}: "           "#{error.message}"
      }
    end

    def safe_runtime_snapshot
      runtime_snapshot
    rescue StandardError
      {
        configured:
          false,
        process_present:
          false,
        process_count:
          0,
        busy_workers:
          0,
        queue_size:
          0,
        scheduled_jobs:
          0,
        retry_jobs:
          0,
        dead_jobs:
          0
      }
    end

    def unavailable_snapshot(
      runtime:,
      migration_pending: false,
      error: nil
    )
      snapshot = {
        module:
          "address_spend_projection",

        source:
          "address_spend_operational_snapshot",

        generated_at:
          Time.current,

        available:
          false,

        status:
          "unavailable",

        migration_pending:
          migration_pending,

        sync: {
          cluster_floor: nil,
          cluster_tip: nil,
          projection_tip: nil,
          lag: nil,
          next_record_height: nil,
          caught_up_to_cluster: false
        },

        activity: {
          processing_height: nil,
          stale_processing: false,
          last_completed_at: nil
        },

        latest_checkpoint: nil,
        failed_checkpoint: nil,
        stale_processing_checkpoint: nil,
        recent_checkpoints: [],

        automation:
          runtime.merge(
            queue_name:
              QUEUE_NAME
          ),

        issues: [
          migration_pending ?
            "migration_pending" :
            "snapshot_error"
        ]
      }

      if error
        snapshot[:error] =
          "#{error.class}: "           "#{error.message}"
      end

      snapshot
    end
  end
end
