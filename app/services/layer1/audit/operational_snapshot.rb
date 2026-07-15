# frozen_string_literal: true

module Layer1
  module Audit
    class OperationalSnapshot
      QUEUE_NAME = "layer1_audit"
      RECENT_RUNS_LIMIT = 20

      def self.call
        new.call
      end

      def initialize(sidekiq_queue: nil, sidekiq_workers: nil)
        @sidekiq_queue = sidekiq_queue
        @sidekiq_workers = sidekiq_workers
      end

      def call
        database = database_snapshot
        sidekiq = sidekiq_snapshot

        build_snapshot(database: database, sidekiq: sidekiq)
      end

      private

      attr_reader :sidekiq_queue, :sidekiq_workers

      def database_snapshot
        recent_runs =
          Layer1AuditRun
            .order(created_at: :desc, id: :desc)
            .limit(RECENT_RUNS_LIMIT)
            .to_a

        latest_run = recent_runs.first
        latest_healthy_run =
          Layer1AuditRun
            .where(status: "healthy")
            .order(created_at: :desc, id: :desc)
            .first

        highest_healthy_height =
          Layer1AuditRun
            .where(status: "healthy")
            .maximum(:audited_height)
            &.to_i

        {
          available: true,
          realtime_tip: realtime_tip,
          latest_run: latest_run,
          latest_healthy_run: latest_healthy_run,
          highest_healthy_height: highest_healthy_height,
          recent_runs: recent_runs
        }
      rescue StandardError
        {
          available: false,
          error_category: "database_error"
        }
      end

      def realtime_tip
        BlockBufferModel
          .where(status: "processed")
          .maximum(:height)
          &.to_i
      end

      def sidekiq_snapshot
        queue = sidekiq_queue || default_sidekiq_queue
        workers = sidekiq_workers || default_sidekiq_workers

        queue_size = Integer(queue.size)
        queue_latency_seconds = numeric_latency(queue.latency)
        worker_count = busy_worker_count(workers)

        {
          available: true,
          queue_size: queue_size,
          queue_latency_seconds: queue_latency_seconds,
          worker_count: worker_count
        }
      rescue StandardError
        {
          available: false,
          error_category: "sidekiq_error",
          queue_size: nil,
          queue_latency_seconds: nil,
          worker_count: nil
        }
      end

      def default_sidekiq_queue
        require "sidekiq/api"

        Sidekiq::Queue.new(QUEUE_NAME)
      end

      def default_sidekiq_workers
        require "sidekiq/api"

        Sidekiq::Workers.new
      end

      def numeric_latency(value)
        return nil if value.nil?

        latency = Float(value)
        return nil unless latency.finite?
        return nil if latency.negative?

        latency.round(3)
      end

      def busy_worker_count(workers)
        workers.count do |*worker_entry|
          work = worker_entry.last
          worker_queue(work) == QUEUE_NAME
        end
      end

      def worker_queue(work)
        return work.queue.to_s if work.respond_to?(:queue)

        payload = work.instance_variable_get(:@hsh) || {}
        payload["queue"] || payload.dig("payload", "queue")
      end

      def build_snapshot(database:, sidekiq:)
        unless database[:available]
          return unavailable_database_snapshot(sidekiq: sidekiq)
        end

        latest_run = database[:latest_run]
        latest_healthy_run = database[:latest_healthy_run]
        highest_healthy_height = database[:highest_healthy_height]
        tip = database[:realtime_tip]
        run_history = database[:recent_runs].map { |run| serialize_run(run) }
        audit_status = audit_status(latest_run)

        {
          status: global_status(audit_status: audit_status, sidekiq: sidekiq),
          audit_status: audit_status,
          activity: activity_status(sidekiq),
          database_available: true,
          sidekiq_available: sidekiq[:available],
          observability: observability(database: database, sidekiq: sidekiq),
          realtime_tip: tip,
          latest_run: serialize_run(latest_run),
          latest_healthy_run: serialize_run(latest_healthy_run),
          highest_healthy_height: highest_healthy_height,
          latest_healthy_lag:
            audit_lag(
              realtime_tip: tip,
              audited_height: latest_healthy_run&.audited_height
            ),
          highest_healthy_lag:
            audit_lag(
              realtime_tip: tip,
              audited_height: highest_healthy_height
            ),
          queue: queue_payload(sidekiq),
          queue_size: sidekiq[:queue_size],
          queue_latency_seconds: sidekiq[:queue_latency_seconds],
          worker_count: sidekiq[:worker_count],
          busy_workers: sidekiq[:worker_count],
          deduplication_expiry_risk: deduplication_expiry_risk(sidekiq),
          run_history: run_history,
          recent_runs: summarize_runs(run_history),
          last_attempted_height: latest_run&.audited_height,
          last_healthy_height: latest_healthy_run&.audited_height,
          last_run: serialize_run(latest_run),
          last_healthy_run: serialize_run(latest_healthy_run)
        }
      end

      def unavailable_database_snapshot(sidekiq:)
        {
          status: "unavailable",
          audit_status: "unavailable",
          activity: "unavailable",
          database_available: false,
          sidekiq_available: sidekiq[:available],
          observability: {
            database_available: false,
            sidekiq_available: sidekiq[:available],
            database_error_category: "database_error",
            sidekiq_error_category: sidekiq[:error_category]
          }.compact,
          realtime_tip: nil,
          latest_run: nil,
          latest_healthy_run: nil,
          highest_healthy_height: nil,
          latest_healthy_lag: nil,
          highest_healthy_lag: nil,
          queue: queue_payload(sidekiq),
          queue_size: sidekiq[:queue_size],
          queue_latency_seconds: sidekiq[:queue_latency_seconds],
          worker_count: sidekiq[:worker_count],
          busy_workers: sidekiq[:worker_count],
          deduplication_expiry_risk: deduplication_expiry_risk(sidekiq),
          run_history: [],
          recent_runs: empty_run_summary,
          last_attempted_height: nil,
          last_healthy_height: nil,
          last_run: nil,
          last_healthy_run: nil
        }
      end

      def audit_status(latest_run)
        return "no_data" unless latest_run

        case latest_run.status
        when "healthy", "failed", "error", "running"
          latest_run.status
        else
          "unknown"
        end
      end

      def global_status(audit_status:, sidekiq:)
        return "critical" if %w[failed error].include?(audit_status)
        return "unavailable" unless sidekiq[:available]

        case audit_status
        when "healthy"
          "healthy"
        when "running"
          "warning"
        else
          audit_status
        end
      end

      def activity_status(sidekiq)
        return "unavailable" unless sidekiq[:available]
        return "running" if sidekiq[:worker_count].positive?
        return "queued" if sidekiq[:queue_size].positive?

        "idle"
      end

      def audit_lag(realtime_tip:, audited_height:)
        return nil if realtime_tip.nil? || audited_height.nil?

        [realtime_tip.to_i - audited_height.to_i, 0].max
      end

      def queue_payload(sidekiq)
        {
          name: QUEUE_NAME,
          size: sidekiq[:queue_size],
          latency_seconds: sidekiq[:queue_latency_seconds]
        }
      end

      def deduplication_expiry_risk(sidekiq)
        marker_ttl_seconds = Layer1::Audit::BlockJob::INITIAL_MARKER_TTL_SECONDS
        queue_latency_seconds = sidekiq[:queue_latency_seconds]

        unless sidekiq[:available] && queue_latency_seconds.is_a?(Numeric)
          return {
            marker_ttl_seconds: marker_ttl_seconds,
            queue_latency_seconds: nil,
            queue_latency_to_ttl_ratio: nil,
            status: "unavailable"
          }
        end

        ratio = queue_latency_seconds.to_f / marker_ttl_seconds.to_f
        status = if ratio >= 1.0
          "critical"
        elsif ratio >= 0.5
          "warning"
        else
          "healthy"
        end

        {
          marker_ttl_seconds: marker_ttl_seconds,
          queue_latency_seconds: queue_latency_seconds,
          queue_latency_to_ttl_ratio: ratio,
          status: status
        }
      end

      def serialize_run(run)
        return nil unless run

        {
          audited_height: run.audited_height,
          status: run.status,
          started_at: run.started_at,
          finished_at: run.finished_at,
          created_at: run.created_at,
          duration_seconds: duration_seconds(run),
          issues_count: Array(run.issues).size
        }
      end

      def duration_seconds(run)
        return nil unless run.started_at && run.finished_at

        (run.finished_at - run.started_at).round(3)
      end

      def summarize_runs(runs)
        {
          sample_size: runs.size,
          healthy: runs.count { |run| run[:status] == "healthy" },
          failed: runs.count { |run| run[:status] == "failed" },
          errors: runs.count { |run| run[:status] == "error" },
          running: runs.count { |run| run[:status] == "running" }
        }
      end

      def empty_run_summary
        {
          sample_size: 0,
          healthy: 0,
          failed: 0,
          errors: 0,
          running: 0
        }
      end

      def observability(database:, sidekiq:)
        {
          database_available: database[:available],
          sidekiq_available: sidekiq[:available],
          sidekiq_error_category: sidekiq[:error_category]
        }.compact
      end
    end
  end
end
