# frozen_string_literal: true

module Layer1
  module Audit
    class OperationalSnapshot
      QUEUE_NAME = "layer1_audit"
      RECENT_RUNS_LIMIT = 20

      def self.call
        new.call
      end

      def call
        last_attempt = latest_attempt
        last_healthy = latest_healthy_attempt
        highest_healthy = highest_healthy_height
        tip = realtime_tip
        queue = queue_snapshot
        workers = busy_workers

        {
          status: health_status(last_attempt),
          activity: activity_state(
            queue_size: queue.fetch(:size),
            busy_workers: workers,
            last_attempt: last_attempt
          ),

          realtime_tip: tip,

          last_attempted_height: last_attempt&.audited_height,
          last_healthy_height: last_healthy&.audited_height,
          highest_healthy_height: highest_healthy,

          last_healthy_lag: audit_lag(
            realtime_tip: tip,
            audited_height: last_healthy&.audited_height
          ),

          highest_healthy_lag: audit_lag(
            realtime_tip: tip,
            audited_height: highest_healthy
          ),

          queue: queue,
          busy_workers: workers,

          last_run: serialize_run(last_attempt),
          last_healthy_run: serialize_run(last_healthy),
          recent_runs: recent_runs_summary
        }
      end

      private

      def realtime_tip
        BlockBufferModel
          .where(status: "processed")
          .maximum(:height)
          &.to_i
      end

      def latest_attempt
        Layer1AuditRun
          .order(created_at: :desc)
          .first
      end

      def latest_healthy_attempt
        Layer1AuditRun
          .where(status: "healthy")
          .order(created_at: :desc)
          .first
      end

      def highest_healthy_height
        Layer1AuditRun
          .where(status: "healthy")
          .maximum(:audited_height)
          &.to_i
      end

      def health_status(last_attempt)
        return "unknown" unless last_attempt

        case last_attempt.status
        when "healthy"
          "healthy"
        when "failed", "error"
          "critical"
        else
          "warning"
        end
      end

      def activity_state(queue_size:, busy_workers:, last_attempt:)
        return "running" if busy_workers.positive?
        return "running" if last_attempt&.status == "running"
        return "queued" if queue_size.positive?

        "idle"
      end

      def audit_lag(realtime_tip:, audited_height:)
        return nil unless realtime_tip && audited_height

        [realtime_tip - audited_height, 0].max
      end

      def queue_snapshot
        require "sidekiq/api"

        queue = Sidekiq::Queue.new(QUEUE_NAME)

        {
          name: QUEUE_NAME,
          size: queue.size,
          latency_seconds: queue.latency.round(3)
        }
      rescue StandardError => e
        {
          name: QUEUE_NAME,
          size: 0,
          latency_seconds: nil,
          error: e.message
        }
      end

      def busy_workers
        require "sidekiq/api"

        Sidekiq::Workers.new.count do |_process_id, _thread_id, work|
          payload = work.instance_variable_get(:@hsh) || {}

          payload["queue"] == QUEUE_NAME
        end
      rescue StandardError
        0
      end

      def serialize_run(run)
        return nil unless run

        {
          audited_height: run.audited_height,
          status: run.status,
          started_at: run.started_at,
          finished_at: run.finished_at,
          duration_seconds: duration_seconds(run),
          issues_count: Array(run.issues).size
        }
      end

      def duration_seconds(run)
        return nil unless run.started_at && run.finished_at

        (run.finished_at - run.started_at).round(3)
      end

      def recent_runs_summary
        runs =
          Layer1AuditRun
            .order(created_at: :desc)
            .limit(RECENT_RUNS_LIMIT)
            .to_a

        {
          sample_size: runs.size,
          healthy: runs.count { |run| run.status == "healthy" },
          failed: runs.count { |run| run.status == "failed" },
          errors: runs.count { |run| run.status == "error" },
          running: runs.count { |run| run.status == "running" }
        }
      end
    end
  end
end
