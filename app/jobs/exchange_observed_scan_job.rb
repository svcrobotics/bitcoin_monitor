# frozen_string_literal: true

class ExchangeObservedScanJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "exchange_observed_scan",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = ExchangeObservedScanner.call

      JobRunner.heartbeat!(jr)

      result
    end
  end
end