# script/bench_btc_cache.rb
# frozen_string_literal: true

require "benchmark"

def bench(label, iterations: 30)
  total = Benchmark.realtime do
    iterations.times { yield }
  end

  avg_ms = (total / iterations) * 1000.0
  puts "#{label.ljust(32)} total=#{format('%.4f', total)}s avg=#{format('%.2f', avg_ms)}ms"
end

def clear_btc_cache!
  keys = [
    Btc::Cache::Keys.summary(market: "btcusd"),
    Btc::Cache::Keys.candles(market: "btcusd", timeframe: "5m", limit: 120),
    Btc::Cache::Keys.candles(market: "btcusd", timeframe: "1h", limit: 120),
    Btc::Cache::Keys.candles_status(market: "btcusd", timeframe: "5m"),
    Btc::Cache::Keys.candles_status(market: "btcusd", timeframe: "1h")
  ]

  keys.each { |key| REDIS.del(key) }
end

puts
puts "======================================"
puts "BTC CACHE BENCHMARK"
puts "BTC_REDIS_DISABLED=#{ENV['BTC_REDIS_DISABLED'].inspect}"
puts "cache_enabled=#{Btc::Cache::Store.cache_enabled?}"
puts "======================================"
puts

puts "--- Cache froid ---"
clear_btc_cache!

bench("SummaryQuery (cold)", iterations: 1) do
  Btc::SummaryQuery.call
end

bench("CandlesQuery 5m (cold)", iterations: 1) do
  Btc::CandlesQuery.call(market: "btcusd", timeframe: "5m", limit: 120)
end

bench("CandlesQuery 1h (cold)", iterations: 1) do
  Btc::CandlesQuery.call(market: "btcusd", timeframe: "1h", limit: 120)
end

bench("CandlesStatus 5m (cold)", iterations: 1) do
  Btc::CandlesStatusQuery.call(market: "btcusd", timeframe: "5m")
end

bench("CandlesStatus 1h (cold)", iterations: 1) do
  Btc::CandlesStatusQuery.call(market: "btcusd", timeframe: "1h")
end

puts
puts "--- Cache chaud ---"

bench("SummaryQuery (warm)") do
  Btc::SummaryQuery.call
end

bench("CandlesQuery 5m (warm)") do
  Btc::CandlesQuery.call(market: "btcusd", timeframe: "5m", limit: 120)
end

bench("CandlesQuery 1h (warm)") do
  Btc::CandlesQuery.call(market: "btcusd", timeframe: "1h", limit: 120)
end

bench("CandlesStatus 5m (warm)") do
  Btc::CandlesStatusQuery.call(market: "btcusd", timeframe: "5m")
end

bench("CandlesStatus 1h (warm)") do
  Btc::CandlesStatusQuery.call(market: "btcusd", timeframe: "1h")
end

puts
puts "--- Taille des payloads Redis ---"
[
  Btc::Cache::Keys.summary(market: "btcusd"),
  Btc::Cache::Keys.candles(market: "btcusd", timeframe: "5m", limit: 120),
  Btc::Cache::Keys.candles(market: "btcusd", timeframe: "1h", limit: 120),
  Btc::Cache::Keys.candles_status(market: "btcusd", timeframe: "5m"),
  Btc::Cache::Keys.candles_status(market: "btcusd", timeframe: "1h")
].each do |key|
  value = REDIS.get(key)
  size = value ? value.bytesize : 0
  puts "#{key.ljust(40)} #{size} bytes"
end

puts
puts "Done."