# frozen_string_literal: true

class ExchangeObservedScanJob < ApplicationJob
  queue_as :p1_exchange

  LOCK_NAME = "exchange_observed_scan_lock"
  LOCK_TTL  = 30.minutes

  def perform
    lock = ScannerCursor.find_or_create_by!(name: LOCK_NAME)

    locked = lock.with_lock do
      if lock.updated_at.present? && lock.updated_at > LOCK_TTL.ago
        false
      else
        lock.touch
        true
      end
    end

    unless locked
      Rails.logger.info("[exchange_observed_scan] skip lock_active")
      return { ok: true, skipped: true, reason: "lock_active" }
    end

    JobRunner.run!(
      "exchange_observed_scan",
      triggered_by: ENV.fetch("TRIGGERED_BY", "sidekiq_cron"),
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = ExchangeObservedScanner.call

      JobRunner.heartbeat!(jr)

      result
    end
  ensure
    lock&.update!(updated_at: LOCK_TTL.ago - 1.second)
  end
end