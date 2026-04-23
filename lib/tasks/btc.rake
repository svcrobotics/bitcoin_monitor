# lib/tasks/btc.rake
# frozen_string_literal: true

namespace :btc do
  namespace :intraday do
    desc "Backfill BTC candles (example: bin/rails btc:intraday:backfill MARKET=btcusd TF=1h LIMIT=300)"
    task backfill: :environment do
      market = ENV.fetch("MARKET", "btcusd")
      timeframe = ENV.fetch("TF", "1h")
      limit = ENV.fetch("LIMIT", "300").to_i

      result = Btc::Ingestion::IntradayBackfill.call(
        market: market,
        timeframe: timeframe,
        limit: limit
      )

      puts "Fetched: #{result[:fetched]}"
      puts "Upserted: #{result[:upserted]}"
    end
  end
end