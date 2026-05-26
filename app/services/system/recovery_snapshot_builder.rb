# frozen_string_literal: true

require "sidekiq/api"
require "set"

module System
  class RecoverySnapshotBuilder
    CURSORS = {
      realtime: "realtime_block_stream",
      exchange: "exchange_observed_scan",
      cluster: "cluster_scan"
    }.freeze

    LOCKS = [
      "realtime_processing_lock",
      "exchange_observed_scan_lock",
      "recovery_orchestrator_lock",
      "lock:cluster_scan"
    ].freeze

    QUEUES = [
      "realtime",
      "ingest",
      "process",
      "p1_exchange",
      "p2_flows",
      "p3_clusters_scan",
      "p3_clusters_refresh",
      "p3_clusters",
      "p4_analytics",
      "default",
      "low"
    ].freeze

    JOB_NAMES = [
      "recovery_orchestrator",
      "exchange_observed_scan",
      "cluster_scan",
      "cluster_refresh_dirty_clusters",
      "cluster_v3_build_metrics",
      "cluster_v3_detect_signals"
    ].freeze

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      best_height = BitcoinRpc.new(wallet: nil).getblockcount.to_i
      cluster_lag = cursor_lag(CURSORS[:cluster], best_height)
      cluster_blocks_per_minute = estimated_blocks_per_minute
      progress = current_job_progress

      {
        generated_at: now,
        best_height: best_height,
        state: System::RecoveryStateBuilder.call,
        layer1: layer1_status(best_height),
        layer1_diagnostics: layer1_diagnostics,
        estimated_blocks_per_minute: cluster_blocks_per_minute,
        eta_minutes: eta_minutes(cluster_lag, cluster_blocks_per_minute),
        current_job_name: progress[:current_job_name],
        current_job_progress_pct: progress[:current_job_progress_pct],
        current_job_progress_label: progress[:current_job_progress_label],
        current_job_progress_meta: progress[:current_job_progress_meta],
        pipelines: build_pipelines(best_height),
        cluster_refresh: cluster_refresh_status,
        queues: build_queues,
        workers: build_workers,
        locks: build_locks,
        recent_job_runs: build_recent_job_runs,
        redis_buffers: redis_buffer_sizes
      }
    rescue StandardError => e
      {
        generated_at: now,
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    attr_reader :now

    def redis_buffer_sizes
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      {
        outputs_buffer: redis.llen("blockchain:outputs:buffer"),
        spent_outputs_buffer: redis.llen("blockchain:spent_outputs:buffer")
      }
    rescue StandardError => e
      {
        error: "#{e.class}: #{e.message}"
      }
    end

    def layer1_status(best_height)
      highest_buffered_height = BlockBufferModel.maximum(:height)
      last_processed_height = BlockBufferModel.where(status: "processed").maximum(:height)
      speed = layer1_recovery_speed

      lag =
        if last_processed_height.present?
          [best_height.to_i - last_processed_height.to_i, 0].max
        end

      {
        best_height: best_height,
        highest_buffered_height: highest_buffered_height,
        last_processed_height: last_processed_height,
        spent_max_height: TxOutput.where.not(spent_block_height: nil).maximum(:spent_block_height),
        exchange_flow_max_height: ExchangeCoreFlowEvent.maximum(:block_height),
        whale_flow_max_day: WhaleCoreFlowDay.maximum(:day),
        fast_path: ENV.fetch("LAYER1_FAST_PATH", "true") == "true",
        lag: lag,
        status_counts: BlockBufferModel.group(:status).count,
        redis_buffers: redis_buffer_sizes,
        process_queue_size: Sidekiq::Queue.new("process").size,
        current_processing_blocks: current_processing_blocks,
        recovery_window: recovery_window(best_height, last_processed_height),
        recent_failed_blocks: recent_failed_blocks,
        recovery_speed: speed,
        eta_minutes: eta_minutes(lag, speed)
      }
    end

    def recovery_window(best_height, last_processed_height)
      limit = Integer(ENV.fetch("LAYER1_RECOVERY_WINDOW_SIZE", "25"))

      upper_bound = best_height.to_i
      lower_bound = [upper_bound - limit + 1, 0].max

      BlockBufferModel
        .where(height: lower_bound..upper_bound)
        .order(height: :desc)
        .map do |block|
          {
            height: block.height,
            status: block.status,
            attempts: block.attempts,
            duration_ms: block.duration_ms,
            rpc_duration_ms: block.rpc_duration_ms,
            parse_duration_ms: block.parse_duration_ms,
            flush_duration_ms: block.flush_duration_ms,
            processing_started_at: block.processing_started_at,
            last_heartbeat_at: block.last_heartbeat_at,
            age_seconds: block.processing_started_at ? (now - block.processing_started_at).to_i : nil,
            heartbeat_age_seconds: block.last_heartbeat_at ? (now - block.last_heartbeat_at).to_i : nil,
            updated_at: block.updated_at,
            processed_at: block.processed_at,
            failed_at: block.failed_at,
            error_class: block.error_class,
            error_message: block.error_message
          }
        end
    end

    def layer1_diagnostics
      process_jobs =
        Sidekiq::Queue.new("process")
          .select { |job| job.klass == "Blockchain::Jobs::BlockProcessJob" }

      queued_heights = process_jobs.map { |job| job.args.first.to_i }

      counts = Hash.new(0)
      queued_heights.each { |height| counts[height] += 1 }

      enqueued_heights = BlockBufferModel.where(status: "enqueued").pluck(:height).map(&:to_i)

      oldest_enqueued = BlockBufferModel.where(status: "enqueued").minimum(:updated_at)
      oldest_processing = BlockBufferModel.where(status: "processing").minimum(:updated_at)

      {
        best_height: BlockBufferModel.maximum(:height),
        processed_height: BlockBufferModel.where(status: "processed").maximum(:height),
        buffers: BlockBufferModel.group(:status).count,
        process_queue_size: Sidekiq::Queue.new("process").size,
        oldest_enqueued_age: oldest_enqueued ? (now - oldest_enqueued).round : nil,
        oldest_processing_age: oldest_processing ? (now - oldest_processing).round : nil,
        orphan_enqueued_count: (enqueued_heights - queued_heights).size,
        orphan_enqueued_heights: (enqueued_heights - queued_heights).sort.first(20),
        process_duplicates_count: counts.count { |_, count| count > 1 },
        process_duplicate_heights: counts.select { |_, count| count > 1 }.keys.sort.first(20),
        redis_pipeline: System::BlockchainPipelineStatus.call
      }
    end

    def build_pipelines(best_height)
      layer1_best_height =
        BlockBufferModel
          .where(status: "processed")
          .maximum(:height)
          .to_i

      {
        
        p1_exchange: pipeline_cursor(
          "P1",
          "Exchange actor enrichment",
          CURSORS[:exchange],
          layer1_best_height,
          description: "Enrichit les acteurs exchange_like utilisés par Exchange Core Flow."
        ),

        p3_cluster_realtime: pipeline_cursor(
          "P3A",
          "Cluster realtime consumer",
          CURSORS[:realtime],
          layer1_best_height
        ),

        p3_cluster_batch: pipeline_cursor(
          "P3B",
          "Cluster batch scanner",
          CURSORS[:cluster],
          layer1_best_height
        )

      }
    end

    def pipeline_cursor(priority, label, cursor_name, best_height, description: nil)
      cursor = ScannerCursor.find_by(name: cursor_name)
      height = cursor&.last_blockheight.to_i
      lag = height.positive? ? [best_height - height, 0].max : best_height

      {
        priority: priority,
        label: label,
        description: description,
        cursor_name: cursor_name,
        status: cursor_status(lag),
        last_height: height,
        best_height: best_height,
        lag: lag,
        updated_at: cursor&.updated_at,
        age_seconds: cursor&.updated_at ? (now - cursor.updated_at).to_i : nil,
        progress_pct: best_height.positive? && height.positive? ? ((height.to_f / best_height) * 100).round(4) : nil
      }
    end

    def cursor_status(lag)
      return "critical" if lag >= 50
      return "warning" if lag >= 5

      "ok"
    end

    def cursor_lag(cursor_name, best_height)
      cursor = ScannerCursor.find_by(name: cursor_name)
      height = cursor&.last_blockheight.to_i

      return best_height if height <= 0

      [best_height - height, 0].max
    end

    def cluster_refresh_status
      dirty_size = Clusters::DirtyClusterQueue.size

      batch_size =
        if dirty_size >= 50_000
          1000
        elsif dirty_size >= 20_000
          500
        elsif dirty_size >= 5_000
          250
        else
          Integer(ENV.fetch("CLUSTER_REFRESH_BATCH_SIZE", "100"))
        end

      last_run =
        JobRun
          .where(name: "cluster_refresh_dirty_clusters")
          .order(started_at: :desc, created_at: :desc)
          .first

      {
        dirty_queue_size: dirty_size,
        batch_size: batch_size,
        estimated_batches_remaining: batch_size.positive? ? (dirty_size.to_f / batch_size).ceil : nil,

        last_run_status: last_run&.status,
        last_run_at: last_run&.started_at,
        last_finish_at: last_run&.finished_at,
        duration_ms: last_run&.duration_ms,
        progress_pct: last_run&.progress_pct,
        progress_label: last_run&.progress_label,
        progress_meta: last_run&.progress_meta
      }
    rescue StandardError => e
      {
        error: "#{e.class}: #{e.message}"
      }
    end

    def build_queues
      QUEUES.map do |name|
        q = Sidekiq::Queue.new(name)

        {
          name: name,
          size: q.size,
          latency: q.latency.round(2)
        }
      end
    end

    def build_workers
      Sidekiq::Workers.new.map do |process_id, thread_id, work|
        raw_payload = work.payload

        payload =
          if raw_payload.is_a?(String)
            JSON.parse(raw_payload)
          else
            raw_payload || {}
          end

        args = payload["args"]
        first_arg = args.is_a?(Array) ? args.first : nil
        active_job_args = first_arg.is_a?(Hash) ? first_arg : {}

        job_class =
          payload["wrapped"].presence ||
          active_job_args["job_class"].presence ||
          payload["class"].presence ||
          "unknown job"

        {
          process_id: process_id,
          thread_id: thread_id,
          queue: work.queue,
          job_class: job_class,
          raw_class: payload["class"],
          wrapped: payload["wrapped"],
          jid: payload["jid"],
          args: active_job_args["arguments"] || args,
          active_job_id: active_job_args["job_id"],
          enqueued_at: active_job_args["enqueued_at"],
          run_at: work.run_at
        }
      rescue JSON::ParserError => e
        {
          process_id: process_id,
          thread_id: thread_id,
          queue: work.queue,
          job_class: "payload parse error",
          error: "#{e.class}: #{e.message}",
          run_at: work.run_at
        }
      end
    end

    def build_locks
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      LOCKS.map do |name|
        value = redis.get(name)
        ttl = redis.ttl(name).to_i

        status =
          if value.present? && ttl.positive?
            "active"
          elsif value.present?
            "stale"
          else
            "clear"
          end

        {
          name: name,
          present: value.present?,
          value: value,
          ttl: ttl,
          status: status
        }
      end
    rescue StandardError => e
      [
        {
          name: "locks",
          status: "error",
          error: "#{e.class}: #{e.message}"
        }
      ]
    end

    def build_recent_job_runs
      JobRun
        .where(name: JOB_NAMES)
        .where("started_at > ?", 24.hours.ago)
        .where.not("error LIKE ?", "Marked failed manually:%")
        .order(started_at: :desc)
        .limit(25)
        .map do |jr|
          {
            name: jr.name,
            status: jr.status,
            started_at: jr.started_at,
            finished_at: jr.finished_at,
            heartbeat_at: jr.heartbeat_at,
            duration_seconds: duration_seconds(jr),
            error_message: jr.respond_to?(:error_message) ? jr.error_message : jr.error,
            progress_pct: jr.progress_pct,
            progress_label: jr.progress_label,
            progress_meta: jr.progress_meta
          }
        end
    end

    def duration_seconds(job_run)
      return nil if job_run.started_at.blank?

      finish = job_run.finished_at || now
      (finish - job_run.started_at).to_i
    end

    def current_recovery_job
      JobRun
        .where(name: JOB_NAMES)
        .where(status: ["running", "started"])
        .order(started_at: :desc)
        .first
    end

    def current_job_progress
      jr = current_recovery_job

      return {
        current_job_name: nil,
        current_job_progress_pct: nil,
        current_job_progress_label: "Aucun job recovery actif",
        current_job_progress_meta: nil
      } unless jr

      {
        current_job_name: jr.name,
        current_job_progress_pct: jr.progress_pct,
        current_job_progress_label: jr.progress_label.presence || "Job en cours",
        current_job_progress_meta: jr.progress_meta
      }
    end

    def estimated_blocks_per_minute
      runs = JobRun
        .where(name: "cluster_scan", status: "ok")
        .where("finished_at > ?", 30.minutes.ago)
        .where.not(duration_ms: nil)
        .order(finished_at: :desc)
        .limit(10)

      return nil if runs.empty?

      limit = Integer(ENV.fetch("CLUSTER_SCAN_LIMIT", "50"))

      durations_minutes =
        runs
          .map { |r| r.duration_ms.to_f / 1000.0 / 60.0 }
          .select(&:positive?)

      return nil if durations_minutes.empty?

      avg_duration = durations_minutes.sum / durations_minutes.size
      (limit / avg_duration).round(2)
    rescue ArgumentError
      nil
    end

    def eta_minutes(lag, blocks_per_minute)
      return nil if lag.to_i <= 0
      return nil if blocks_per_minute.to_f <= 0

      (lag.to_f / blocks_per_minute.to_f).ceil
    end

    def current_processing_blocks
      BlockBufferModel
        .where(status: "processing")
        .order(:height)
        .limit(20)
        .map do |block|
          {
            height: block.height,
            attempts: block.attempts,
            processing_started_at: block.processing_started_at,
            last_heartbeat_at: block.last_heartbeat_at,
            age_seconds: block.processing_started_at ? (now - block.processing_started_at).to_i : nil,
            heartbeat_age_seconds: block.last_heartbeat_at ? (now - block.last_heartbeat_at).to_i : nil,
            rpc_duration_ms: block.rpc_duration_ms,
            parse_duration_ms: block.parse_duration_ms,
            flush_duration_ms: block.flush_duration_ms
          }
        end
    end

    def recent_failed_blocks
      BlockBufferModel
        .where(status: "failed")
        .order(updated_at: :desc)
        .limit(10)
        .map do |block|
          {
            height: block.height,
            attempts: block.attempts,
            failed_at: block.failed_at,
            error_class: block.error_class,
            error_message: block.error_message
          }
        end
    end

    def layer1_recovery_speed
      processed = BlockBufferModel
        .where(status: "processed")
        .where("processed_at > ?", 30.minutes.ago)
        .count

      return nil if processed.zero?

      (processed / 30.0).round(2)
    end
  end
end