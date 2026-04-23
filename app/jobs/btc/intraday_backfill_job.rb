# app/jobs/btc/intraday_backfill_job.rb
# frozen_string_literal: true

module Btc
  class IntradayBackfillJob < ApplicationJob
    queue_as :default

    def perform(market: "btcusd", timeframe: "1h", limit: 300)
      Btc::Ingestion::IntradayBackfill.call(
        market: market,
        timeframe: timeframe,
        limit: limit
      )
    end
  end
end