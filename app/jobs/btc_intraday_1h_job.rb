# frozen_string_literal: true

class BtcIntraday1hJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "btc_intraday_1h",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = Btc::Ingestion::IntradayBackfill.call(
        market: "btcusd",
        timeframe: "1h"
      )

      JobRunner.heartbeat!(jr)

      result
    end
  end
end