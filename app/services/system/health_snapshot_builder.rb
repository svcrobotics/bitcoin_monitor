# app/services/system/health_snapshot_builder.rb
module System
  class HealthSnapshotBuilder
    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      jobs = System::JobHealthSnapshotBuilder.call(now: @now)

      {
        generated_at: @now,
        summary: build_summary(jobs),
        anomalies: build_anomalies(jobs),
        recovery: build_recovery(jobs),
        jobs: jobs
      }
    end

    private

    def build_summary(jobs)
      active_jobs = jobs.select { |j| j[:active] }
      critical_jobs = active_jobs.select { |j| j[:critical] }

      {
        active_jobs_count: active_jobs.size,
        critical_jobs_count: critical_jobs.size,
        ok_jobs_count: active_jobs.count { |j| j[:status] == "ok" },
        late_jobs_count: active_jobs.count { |j| j[:status] == "late" },
        failing_jobs_count: active_jobs.count { |j| j[:status] == "failing" },
        long_running_jobs_count: active_jobs.count { |j| j[:status] == "long_running" },
        running_jobs_count: active_jobs.count { |j| j[:status] == "running" },
        healthy_critical_jobs_count: critical_jobs.count { |j| j[:status] == "ok" }
      }
    end

    def build_anomalies(jobs)
      jobs.select do |j|
        %w[late failing long_running never_ran warning].include?(j[:status])
      end
    end

    def build_recovery(jobs)
      critical_problems = jobs.select do |j|
        j[:critical] && %w[late failing long_running never_ran warning].include?(j[:status])
      end

      {
        recovery_needed: critical_problems.any?,
        critical_problems_count: critical_problems.size,
        critical_problems: critical_problems.map { |j| { name: j[:name], status: j[:status] } },
        restart_order: jobs
          .select { |j| j[:active] && j[:critical] }
          .sort_by { |j| SYSTEM_JOBS.fetch(j[:name]).fetch(:order, 999) }
          .map { |j| j[:name] }
      }
    end
  end
end