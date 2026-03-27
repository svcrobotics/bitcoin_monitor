# app/services/job_runner.rb
require "json"

class JobRunner
  def self.run!(name, meta: {})
    jr = JobRun.create!(
      name: name,
      status: "running",
      started_at: Time.current,
      meta: meta.to_json
    )

    begin
      result = yield

      jr.update!(
        status: "ok",
        finished_at: Time.current,
        duration_ms: ((Time.current - jr.started_at) * 1000).to_i,
        exit_code: 0
      )

      result
    rescue => e
      jr.update!(
        status: "failed",
        finished_at: Time.current,
        duration_ms: ((Time.current - jr.started_at) * 1000).to_i,
        exit_code: 1,
        error: "#{e.class}: #{e.message}\n#{e.backtrace&.first(30)&.join("\n")}"
      )
      raise
    end
  end
end
