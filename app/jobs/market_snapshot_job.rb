# frozen_string_literal: true

class MarketSnapshotJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "market_snapshot",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = MarketSnapshotBuilder.call

      JobRunner.heartbeat!(jr)

      result
    end
  end
end
