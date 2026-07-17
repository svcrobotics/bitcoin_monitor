# frozen_string_literal: true

module ClusterTransactionProjection
  class OperationalSnapshot
    ENABLED_ENV =
      "CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"

    MIN_FREE_BYTES_ENV =
      "CLUSTER_TRANSACTION_PROJECTION_MIN_FREE_BYTES"

    BUDGET_SECONDS_ENV =
      "CLUSTER_TRANSACTION_PROJECTION_SCHEDULER_BUDGET_SECONDS"

    DEFAULT_MIN_FREE_BYTES = 25.gigabytes
    DEFAULT_BUDGET_SECONDS = 30
    MIN_BUDGET_SECONDS = 5
    MAX_BUDGET_SECONDS = 60

    WORK_STATUSES = %w[
      pending
      building
      paused
      ready_to_certify
    ].freeze

    def self.call(current_snapshot: nil)
      new(current_snapshot: current_snapshot).call
    end

    def self.enabled?
      ActiveModel::Type::Boolean
        .new
        .cast(
          ENV.fetch(ENABLED_ENV, "0")
        ) == true
    end

    def self.min_free_bytes
      Integer(
        ENV.fetch(
          MIN_FREE_BYTES_ENV,
          DEFAULT_MIN_FREE_BYTES.to_s
        )
      )
    rescue ArgumentError, TypeError
      DEFAULT_MIN_FREE_BYTES
    end

    def self.scheduler_budget_seconds
      raw =
        Integer(
          ENV.fetch(
            BUDGET_SECONDS_ENV,
            DEFAULT_BUDGET_SECONDS.to_s
          )
        )

      raw.clamp(MIN_BUDGET_SECONDS, MAX_BUDGET_SECONDS)
    rescue ArgumentError, TypeError
      DEFAULT_BUDGET_SECONDS
    end

    def initialize(current_snapshot: nil)
      @current_snapshot = current_snapshot || {}
    end

    def call
      run = active_run
      item = current_item(run)
      free = disk_free_bytes
      min_free = self.class.min_free_bytes
      enabled = self.class.enabled?
      work = enabled && run.present? && item.present?

      {
        enabled: enabled,
        pipeline_state:
          state_for(enabled, run, item, free, min_free),
        wait_reason:
          wait_reason_for(enabled, run, item, free, min_free),
        active_run_id: run&.id,
        active_run_status: run&.status,
        remaining_items: remaining_items(run),
        current_item: item_payload(item),
        current_stage: item&.stage,
        cursor: item&.source_cursor || {},
        last_chunk_duration_ms: last_chunk_duration_ms(item),
        last_run_at: last_run_at(item),
        last_result: run&.last_error,
        strict_io_owner: @current_snapshot.dig(:strict_io, :owner),
        free_disk_bytes: free,
        min_free_disk_bytes: min_free,
        projected_free_disk_bytes: free,
        scheduler_budget_seconds:
          self.class.scheduler_budget_seconds,
        work_available: work
      }
    rescue StandardError => error
      {
        enabled: self.class.enabled?,
        pipeline_state: "failed",
        wait_reason: "snapshot_error",
        error: "#{error.class}: #{error.message}",
        work_available: false,
        scheduler_budget_seconds:
          self.class.scheduler_budget_seconds,
        min_free_disk_bytes:
          self.class.min_free_bytes
      }
    end

    private

    def active_run
      ClusterTransactionProjectionBackfillRun
        .where(status: %w[pending running paused])
        .order(id: :asc)
        .first
    end

    def current_item(run)
      return nil unless run

      run
        .items
        .where(status: WORK_STATUSES)
        .order(:id)
        .first
    end

    def remaining_items(run)
      return 0 unless run

      run.items.where(status: WORK_STATUSES).count
    end

    def item_payload(item)
      return nil unless item

      {
        id: item.id,
        cluster_id: item.cluster_id,
        status: item.status,
        stage: item.stage,
        source_cursor: item.source_cursor
      }
    end

    def state_for(enabled, run, item, free, min_free)
      return "disabled" unless enabled
      return "waiting_disk" if free.to_i < min_free.to_i
      return "idle_no_run" unless run
      return "running" if run.status == "running"
      return "completed" if run.status == "completed"
      return "failed" if run.status == "failed"
      return "paused" if run.status == "paused"

      return "idle_no_run" unless item

      case wait_reason_for(enabled, run, item, free, min_free)
      when "no_incomplete_run"
        "idle_no_run"
      when "phase_layer1_catchup",
           "layer1_priority",
           "cluster_priority",
           "address_spend_priority"
        "waiting_upstream"
      when "actor_profile_v5_priority"
        "waiting_actor_profile_v5"
      when "strict_io_busy"
        "waiting_io"
      when "disk_guard"
        "waiting_disk"
      when "checkpoint_invalid",
           "composition_invalid"
        "stale"
      else
        "runnable"
      end
    end

    def wait_reason_for(enabled, run, item, free, min_free)
      return "feature_disabled" unless enabled
      return "disk_guard" if free.to_i < min_free.to_i
      return "no_incomplete_run" unless run && item

      return "phase_layer1_catchup" if
        development_backfill_phase_layer1_catchup?

      return "strict_io_busy" if @current_snapshot.dig(:strict_io, :owner).present?

      return "layer1_priority" if layer1_priority?
      return "cluster_priority" if cluster_priority?
      return "address_spend_priority" if address_spend_priority?
      return "actor_profile_v5_priority" if actor_profile_v5_priority?
      return "checkpoint_invalid" if checkpoint_invalid?(run)
      return "composition_invalid" if composition_invalid?(run)

      nil
    end

    def development_backfill_phase_layer1_catchup?
      @current_snapshot.dig(:development_backfill, :phase).to_s ==
        "layer1_catchup"
    end

    def layer1_priority?
      layer1 = @current_snapshot.fetch(:layer1, {})

      layer1[:processing] == true ||
        layer1[:strict_queue_size].to_i.positive? ||
        layer1[:strict_worker_busy] == true
    end

    def cluster_priority?
      cluster = @current_snapshot.fetch(:cluster, {})

      cluster[:processing] == true ||
        cluster[:strict_queue_size].to_i.positive? ||
        cluster[:strict_worker_busy] == true ||
        cluster[:lag].to_i.positive?
    end

    def address_spend_priority?
      projection = @current_snapshot.fetch(:address_spend_projection, {})

      projection[:processing] == true ||
        (
          projection[:work_available] == true &&
            projection[:caught_up_to_cluster] != true
        )
    end

    def actor_profile_v5_priority?
      profile = @current_snapshot.fetch(:actor_profile, {})

      profile[:processing] == true ||
        profile[:pending_work].to_i.positive? ||
        profile[:strict_queue_size].to_i.positive? ||
        profile[:strict_worker_busy] == true
    end

    def checkpoint_invalid?(run)
      checkpoint =
        ClusterProcessedBlock.find_by(
          height: run.target_checkpoint_height
        )

      checkpoint.nil? ||
        checkpoint.block_hash.to_s != run.target_checkpoint_hash.to_s
    end

    def composition_invalid?(run)
      run
        .items
        .joins(
          "INNER JOIN clusters ON clusters.id = cluster_transaction_projection_backfill_items.cluster_id"
        )
        .where(
          "clusters.composition_version <> cluster_transaction_projection_backfill_items.composition_version"
        )
        .exists?
    end

    def last_chunk_duration_ms(item)
      chunks =
        Array(
          item&.metrics&.fetch("chunks", nil)
        )

      chunks.last&.fetch("duration_ms", nil)
    end

    def last_run_at(item)
      chunks =
        Array(
          item&.metrics&.fetch("chunks", nil)
        )

      chunks.last&.fetch("recorded_at", nil)
    end

    def disk_free_bytes
      line =
        IO
          .popen(["df", "-Pk", Rails.root.to_s], &:read)
          .lines
          .last

      line.split[3].to_i * 1024
    end
  end
end
