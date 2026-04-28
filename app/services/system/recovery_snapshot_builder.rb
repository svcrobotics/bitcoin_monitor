# frozen_string_literal: true

require "sidekiq/api"

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
      "recovery_orchestrator_lock"
    ].freeze

    QUEUES = [
      "realtime",
      "p1_exchange",
      "p2_flows",
      "p3_clusters",
      "p4_analytics",
      "default"
    ].freeze

    JOB_NAMES = [
      "recovery_orchestrator",
      "clusters_realtime_pipeline",
      "exchange_observed_scan",
      "inflow_outflow_build",
      "inflow_outflow_details_build",
      "inflow_outflow_behavior_build",
      "inflow_outflow_capital_behavior_build",
      "cluster_scan",
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
        estimated_blocks_per_minute: cluster_blocks_per_minute,
        eta_minutes: eta_minutes(cluster_lag, cluster_blocks_per_minute),
        current_job_name: progress[:current_job_name],
        current_job_progress_pct: progress[:current_job_progress_pct],
        current_job_progress_label: progress[:current_job_progress_label],
        current_job_progress_meta: progress[:current_job_progress_meta],
        pipelines: build_pipelines(best_height),
        queues: build_queues,
        workers: build_workers,
        locks: build_locks,
        recent_job_runs: build_recent_job_runs
      }
    rescue StandardError => e
      {
        generated_at: now,
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    attr_reader :now

    def build_pipelines(best_height)
      {
        p0_realtime: pipeline_cursor("P0", "Realtime processor", CURSORS[:realtime], best_height),
        p1_exchange: pipeline_cursor("P1", "Exchange observed scan", CURSORS[:exchange], best_height),
        p2_flows: pipeline_data("P2", "Inflow / Outflow", flow_tables),
        p3_clusters: pipeline_cursor("P3", "Cluster scan", CURSORS[:cluster], best_height),
        p4_analytics: pipeline_data("P4", "Cluster analytics", analytics_tables)
      }
    end

    def pipeline_cursor(priority, label, cursor_name, best_height)
      cursor = ScannerCursor.find_by(name: cursor_name)
      height = cursor&.last_blockheight.to_i
      lag = height.positive? ? [best_height - height, 0].max : best_height

      {
        priority: priority,
        label: label,
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

    def pipeline_data(priority, label, tables)
      worst_status =
        if tables.any? { |t| t[:status] == "critical" }
          "critical"
        elsif tables.any? { |t| t[:status] == "warning" }
          "warning"
        else
          "ok"
        end

      {
        priority: priority,
        label: label,
        status: worst_status,
        tables: tables
      }
    end

    def flow_tables
      expected = Date.yesterday

      [
        table_day_status("exchange_flow_days", ExchangeFlowDay.maximum(:day), expected),
        table_day_status("exchange_flow_day_details", ExchangeFlowDayDetail.maximum(:day), expected),
        table_day_status("exchange_flow_day_behaviors", ExchangeFlowDayBehavior.maximum(:day), expected),
        table_day_status("exchange_flow_day_capital_behaviors", ExchangeFlowDayCapitalBehavior.maximum(:day), expected)
      ]
    end

    def analytics_tables
      expected = Date.yesterday

      [
        table_day_status("cluster_metrics", ClusterMetric.maximum(:snapshot_date), expected),
        table_day_status("cluster_signals", ClusterSignal.maximum(:snapshot_date), expected)
      ]
    end

    def table_day_status(name, last_day, expected_day)
      lag_days =
        if last_day.present?
          [expected_day - last_day.to_date, 0].max.to_i
        end

      status =
        if last_day.blank?
          "critical"
        elsif lag_days >= 2
          "critical"
        elsif lag_days == 1
          "warning"
        else
          "ok"
        end

      {
        name: name,
        status: status,
        last_day: last_day,
        expected_day: expected_day,
        lag_days: lag_days
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
      Sidekiq::Workers.new.map do |_, _, work|
        payload = work.payload

        {
          queue: work.queue,
          job_class: payload["wrapped"] || payload["class"],
          run_at: work.run_at
        }
      end
    end

    def build_locks
      LOCKS.map do |name|
        cursor = ScannerCursor.find_by(name: name)

        {
          name: name,
          updated_at: cursor&.updated_at,
          age_seconds: cursor&.updated_at ? (now - cursor.updated_at).to_i : nil
        }
      end
    end

    def build_recent_job_runs
      JobRun
        .where(name: JOB_NAMES)
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
  end
end