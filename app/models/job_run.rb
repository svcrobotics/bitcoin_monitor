# frozen_string_literal: true

class JobRun < ApplicationRecord
  scope :recent, -> { order(started_at: :desc) }
  scope :for_job, ->(name) { where(name: name) }

  def self.log!(name, meta: nil)
    jr = create!(
      name: name,
      status: "running",
      started_at: Time.current,
      meta: meta
    )

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

    jr.update!(
      status: "ok",
      finished_at: Time.current,
      duration_ms: ms,
      exit_code: 0
    )

    jr
  rescue => e
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round rescue nil

    jr&.update!(
      status: "fail",
      finished_at: Time.current,
      duration_ms: ms,
      exit_code: 1,
      error: "#{e.class}: #{e.message}"
    )

    raise
  end
end

