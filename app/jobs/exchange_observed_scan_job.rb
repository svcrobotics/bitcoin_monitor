# frozen_string_literal: true

class ExchangeObservedScanJob < ApplicationJob
  queue_as :p1_exchange

  LOCK_KEY = "lock:exchange_observed_scan"
  LOCK_TTL = 30.minutes.to_i

  def perform
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

    locked = redis.set(
      LOCK_KEY,
      "#{Process.pid}:#{Time.current.to_i}",
      nx: true,
      ex: LOCK_TTL
    )

    unless locked
      Rails.logger.info("[exchange_observed_scan] skip already_running redis_lock=#{LOCK_KEY}")
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
    redis&.del(LOCK_KEY)
  end
end