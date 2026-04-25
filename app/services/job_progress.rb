# frozen_string_literal: true

class JobProgress
  def self.update!(name:, current:, total:, label_prefix: nil)
    return if total.to_i <= 0

    pct = ((current.to_f / total.to_f) * 100).round(1)
    pct = [[pct, 0].max, 100].min

    label =
      if label_prefix.present?
        "#{label_prefix} #{current} / #{total}"
      else
        "#{current} / #{total}"
      end

    job = JobRun.where(name: name, status: "running").order(created_at: :desc).first
    return unless job

    job.update!(
      progress_pct: pct,
      progress_label: label,
      heartbeat_at: Time.current
    )
  rescue => e
    Rails.logger.warn("[job_progress] #{name} failed: #{e.class} #{e.message}")
  end
end