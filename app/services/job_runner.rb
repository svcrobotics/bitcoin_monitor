# app/services/job_runner.rb
require "json"

class JobRunner
  def self.run!(name, meta: {}, triggered_by: "manual", scheduled_for: nil)
    jr = JobRun.create!(
      name: name,
      status: "running",
      started_at: Time.current,
      heartbeat_at: Time.current,
      triggered_by: triggered_by,
      scheduled_for: scheduled_for,
      meta: meta.to_json
    )

    begin
      result = yield(jr)

      jr.update!(
        status: "ok",
        finished_at: Time.current,
        heartbeat_at: Time.current,
        duration_ms: ((Time.current - jr.started_at) * 1000).to_i,
        exit_code: 0
      )

      result
    rescue => e
      jr.update!(
        status: "fail",
        finished_at: Time.current,
        heartbeat_at: Time.current,
        duration_ms: ((Time.current - jr.started_at) * 1000).to_i,
        exit_code: 1,
        error: "#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}"
      )
      raise
    end
  end

  def self.heartbeat!(job_run)
    return unless job_run&.persisted?
    job_run.update_columns(heartbeat_at: Time.current)
  end

  def self.skip!(name, reason:, triggered_by: "cron", scheduled_for: nil, meta: {})
    JobRun.create!(
      name: name,
      status: "skipped",
      started_at: Time.current,
      finished_at: Time.current,
      heartbeat_at: Time.current,
      triggered_by: triggered_by,
      scheduled_for: scheduled_for,
      exit_code: 0,
      error: reason,
      meta: meta.to_json
    )
  end

  def self.progress!(job_run, pct: nil, label: nil, meta: {})
    return unless job_run&.persisted?

    job_run.update_columns(
      progress_pct: pct,
      progress_label: label,
      progress_meta: meta.presence,
      heartbeat_at: Time.current
    )
  end
end