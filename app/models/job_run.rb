# app/models/job_run.rb
class JobRun < ApplicationRecord
  scope :for_job, ->(name) { where(name: name) }
  scope :recent, -> { order(started_at: :desc, created_at: :desc) }
  STATUSES = %w[running ok fail skipped].freeze
  TRIGGERS = %w[cron manual recovery].freeze

  validates :name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :triggered_by, inclusion: { in: %w[cron manual recovery sidekiq_cron] }, allow_blank: true

  scope :recent, -> { order(started_at: :desc, created_at: :desc) }
  scope :running, -> { where(status: "running") }
  scope :failed, -> { where(status: "fail") }
  scope :ok, -> { where(status: "ok") }
  scope :skipped, -> { where(status: "skipped") }

  def running?
    status == "running"
  end

  def ok?
    status == "ok"
  end

  def fail?
    status == "fail"
  end

  def skipped?
    status == "skipped"
  end

  def error_message
    error
  end
end