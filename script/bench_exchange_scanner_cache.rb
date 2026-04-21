# frozen_string_literal: true

require "benchmark"

def measure(label)
  t = Benchmark.realtime { yield }
  puts "#{label}: #{t.round(3)}s"
  t
end

def run_scanner(window)
  ExchangeObservedScanner.call(last_n_blocks: window)
end

WINDOW = ENV.fetch("WINDOW", "10").to_i
RUNS   = ENV.fetch("RUNS", "3").to_i

puts "== Benchmark ExchangeObservedScanner =="
puts "window=#{WINDOW} runs=#{RUNS}"
puts

# 1) Sans cache: invalidate avant chaque run
no_cache_times = []
RUNS.times do |i|
  ExchangeLike::ScannableAddressesCache.invalidate!
  t = measure("no_cache_run_#{i + 1}") do
    run_scanner(WINDOW)
  end
  no_cache_times << t
end

puts

# 2) Cache cold: un seul run après invalidation
ExchangeLike::ScannableAddressesCache.invalidate!
cold_time = measure("cache_cold_run") do
  run_scanner(WINDOW)
end

puts

# 3) Cache warm: plusieurs runs successifs sans invalidation
warm_times = []
RUNS.times do |i|
  t = measure("cache_warm_run_#{i + 1}") do
    run_scanner(WINDOW)
  end
  warm_times << t
end

puts
avg_no_cache = no_cache_times.sum / no_cache_times.size
avg_warm     = warm_times.sum / warm_times.size

gain_abs = avg_no_cache - avg_warm
gain_pct = avg_no_cache.positive? ? (gain_abs / avg_no_cache * 100.0) : 0.0

puts "== Summary =="
puts "avg_no_cache: #{avg_no_cache.round(3)}s"
puts "cold_cache:   #{cold_time.round(3)}s"
puts "avg_warm:     #{avg_warm.round(3)}s"
puts "gain_abs:     #{gain_abs.round(3)}s"
puts "gain_pct:     #{gain_pct.round(2)}%"
