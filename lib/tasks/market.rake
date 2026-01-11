# lib/tasks/market.rake
namespace :market do
  desc "Fetch daily BTC prices (CoinGecko) and upsert into btc_price_days"
  task fetch_prices: :environment do
    days = (ENV["DAYS"] || "365").to_i

    result = MarketData::FetchDailyPrices.new(days: days).call
    puts "✅ OK: #{result.inspect}"
  rescue MarketData::FetchDailyPrices::Error => e
    warn "❌ ERROR: #{e.message}"
    exit 1
  end

  desc "Fetch prices + compute market snapshot"
  task refresh: :environment do
    days = (ENV["DAYS"] || "365").to_i

    snapshot = MarketData::RefreshMarketContext.new(days: days).call

    puts "✅ Snapshot OK: id=#{snapshot.id} bias=#{snapshot.market_bias} cycle=#{snapshot.cycle_zone} risk=#{snapshot.risk_level}"
    snapshot.reasons.each { |r| puts " - #{r}" }
  rescue => e
    warn "❌ ERROR: #{e.class} #{e.message}"
    exit 1
  end
end
