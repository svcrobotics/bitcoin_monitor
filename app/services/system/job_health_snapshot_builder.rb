# app/services/system/job_health_snapshot_builder.rb
module System
  class JobHealthSnapshotBuilder
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      ::SYSTEM_JOBS
        .sort_by { |_name, cfg| cfg[:order] || 999 }
        .map { |name, cfg| build_one(name, cfg) }
    end

    private

    attr_reader :now

    def build_one(name, cfg)
      runs = JobRun.where(name: name).order(started_at: :desc, created_at: :desc).limit(30).to_a

      last_run     = runs.first
      last_ok      = runs.find { |r| r.status == "ok" }
      last_fail    = runs.find { |r| r.status == "fail" }
      last_skipped = runs.find { |r| r.status == "skipped" }
      running      = runs.find { |r| r.status == "running" && r.finished_at.nil? }

      ok_runs = runs.select { |r| r.status == "ok" && r.duration_ms.present? }.first(10)
      durations = ok_runs.map(&:duration_ms)

      ref_time = last_ok&.finished_at || last_ok&.started_at || last_run&.finished_at || last_run&.started_at || last_run&.created_at

      expected_every_seconds = cfg[:expected_every].to_i
      late_after_seconds     = (cfg[:late_after] || (cfg[:expected_every] * 2)).to_i

      delay_seconds =
        if cfg[:active] && ref_time.present?
          [(now - ref_time - expected_every_seconds), 0].max.to_i
        end

      age_since_last_ok_seconds =
        if last_ok&.finished_at.present?
          (now - last_ok.finished_at).to_i
        elsif last_ok&.started_at.present?
          (now - last_ok.started_at).to_i
        end

      missed_runs =
        if cfg[:active] && ref_time.present? && expected_every_seconds.positive?
          [(((now - ref_time) / expected_every_seconds).floor - 1), 0].max
        end

      consecutive_failures = consecutive_failures_for(runs)

      current_runtime_seconds =
        if running&.started_at
          (now - running.started_at).to_i
        end

      heartbeat_age_seconds =
        if running&.heartbeat_at
          (now - running.heartbeat_at).to_i
        end

      avg_duration_ms = average(durations)
      max_duration_ms = durations.max
      capacity_status = compute_capacity_status(cfg, avg_duration_ms)

      status = compute_status(
        cfg: cfg,
        last_run: last_run,
        last_ok: last_ok,
        last_fail: last_fail,
        running: running,
        age_since_last_ok_seconds: age_since_last_ok_seconds,
        late_after_seconds: late_after_seconds,
        consecutive_failures: consecutive_failures,
        current_runtime_seconds: current_runtime_seconds,
        heartbeat_age_seconds: heartbeat_age_seconds
      )

      {
        name: name,
        label: cfg[:label],
        category: cfg[:category],
        active: cfg[:active],
        critical: cfg[:critical],
        cron: cfg[:cron],
        command: cfg[:command],
        lock_file: cfg[:lock_file],
        lock_present: cfg[:lock_file].present? ? File.exist?(cfg[:lock_file]) : false,

        expected_every: cfg[:expected_every],
        late_after: cfg[:late_after] || (cfg[:expected_every] * 2),
        max_runtime: cfg[:max_runtime],

        status: status,
        capacity_status: capacity_status,

        running: running.present?,
        current_runtime_seconds: current_runtime_seconds,
        heartbeat_age_seconds: heartbeat_age_seconds,

        last_run_at: last_run&.started_at || last_run&.created_at,
        last_finish_at: last_run&.finished_at,
        last_ok_at: last_ok&.finished_at || last_ok&.started_at,
        last_fail_at: last_fail&.finished_at || last_fail&.started_at,
        last_skipped_at: last_skipped&.finished_at || last_skipped&.started_at,

        last_duration_ms: last_ok&.duration_ms,
        avg_duration_ms: avg_duration_ms,
        max_duration_ms: max_duration_ms,

        last_exit_code: last_run&.exit_code,
        last_error:
          if last_run&.status == "fail"
            last_run.error
          elsif last_run&.status == "skipped"
            last_run.error
          end,

        last_triggered_by: last_run&.triggered_by,

        progress_pct: running&.progress_pct,
        progress_label: running&.progress_label,

        delay_seconds: delay_seconds,
        age_since_last_ok_seconds: age_since_last_ok_seconds,
        missed_runs: missed_runs,

        failures_in_last_10: runs.first(10).count { |r| r.status == "fail" },
        skips_in_last_10: runs.first(10).count { |r| r.status == "skipped" },
        consecutive_failures: consecutive_failures
      }
    end

    def compute_status(cfg:, last_run:, last_ok:, last_fail:, running:, age_since_last_ok_seconds:, late_after_seconds:, consecutive_failures:, current_runtime_seconds:, heartbeat_age_seconds:)
      return "disabled" unless cfg[:active]
      return "never_ran" if last_run.nil?

      if running
        return "stuck" if heartbeat_age_seconds.present? && heartbeat_age_seconds > cfg[:max_runtime].to_i
        return "long_running" if current_runtime_seconds.to_i > cfg[:max_runtime].to_i
        return "running"
      end

      return "failing" if consecutive_failures >= 2
      return "warning" if last_fail.present? && last_ok.nil?

      if age_since_last_ok_seconds.present? && age_since_last_ok_seconds > late_after_seconds
        return "late"
      end

      "ok"
    end

    def compute_capacity_status(cfg, avg_duration_ms)
      return "unknown" if avg_duration_ms.blank?

      avg_seconds      = avg_duration_ms / 1000.0
      expected_seconds = cfg[:expected_every].to_i
      return "unknown" if expected_seconds <= 0

      ratio = avg_seconds / expected_seconds

      if ratio > 1.0
        "over"
      elsif ratio >= 0.8
        "tight"
      else
        "ok"
      end
    end

    def consecutive_failures_for(runs)
      count = 0

      runs.each do |run|
        case run.status
        when "fail"
          count += 1
        when "ok"
          break
        end
      end

      count
    end

    def average(values)
      return nil if values.empty?
      (values.sum / values.size.to_f).round
    end
  end
end