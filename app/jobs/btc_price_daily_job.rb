# frozen_string_literal: true

class BtcPriceDailyJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "btc_price_daily",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      target_day = Date.yesterday
      result = BtcPriceDaysCatchup.call(target_day: target_day)

      JobRunner.heartbeat!(jr)

      result
    end
  end
end
