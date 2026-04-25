# frozen_string_literal: true

class BtcIntraday5mJob < ApplicationJob
  queue_as :default

  def perform
    JobRunner.run!(
      "btc_intraday_5m",
      triggered_by: "sidekiq_cron",
      scheduled_for: Time.current.strftime("%Y-%m-%d %H:%M:%S")
    ) do |jr|
      JobRunner.heartbeat!(jr)

      result = Btc::Ingestion::IntradayBackfill.call(
        market: "btcusd",
        timeframe: "5m"
      )

      JobRunner.heartbeat!(jr)

      result
    end
  end
end