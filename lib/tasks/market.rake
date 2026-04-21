# frozen_string_literal: true

# lib/tasks/market.rake
require "json"

namespace :market do
  desc "Build daily BTC prices (composite: kraken/coinbase/bitstamp) and upsert into btc_price_days"
  task fetch_prices: :environment do
    days_back = (ENV["DAYS_BACK"] || ENV["DAYS"] || "365").to_i
    days_back = 1 if days_back < 1

    tz = ActiveSupport::TimeZone[Rails.application.config.time_zone] || Time.zone
    target_day = tz.now.to_date - 1
    start_day  = target_day - (days_back - 1)

    name = "btc_price_daily"

    JobRunner.run!(
      name,
      meta: { days_back: days_back, start_day: start_day.to_s, target_day: target_day.to_s },
      triggered_by: "cron"
    ) do |jr|
      JobRunner.heartbeat!(jr)

      puts "[market:fetch_prices] range=#{start_day}..#{target_day} days_back=#{days_back}"

      ok = 0
      failed = 0
      fails = []
      total = (target_day - start_day).to_i + 1

      (start_day..target_day).each_with_index do |day, idx|
        begin
          BtcPriceDayBuilder.call(day: day)
          ok += 1
        rescue => e
          failed += 1
          fails << { day: day.to_s, error: "#{e.class}: #{e.message}" }
          warn "[market:fetch_prices] fail day=#{day} #{e.class}: #{e.message}"
        end

        if (idx % 10).zero? || day == target_day
          JobRunner.progress!(
            jr,
            pct: total.positive? ? (((idx + 1).to_f / total) * 100).round(1) : 100.0,
            label: "day #{day} (#{idx + 1}/#{total})",
            meta: {
              days_back: days_back,
              start_day: start_day.to_s,
              target_day: target_day.to_s,
              processed: idx + 1,
              total: total,
              ok: ok,
              failed: failed
            }
          )
        end
      end

      JobRunner.heartbeat!(jr)

      result = { ok: ok, failed: failed, range: "#{start_day}..#{target_day}" }
      puts "✅ OK: #{result.inspect}"

      jr.update!(
        meta: {
          days_back: days_back,
          start_day: start_day.to_s,
          target_day: target_day.to_s,
          result: result,
          fails: fails
        }.to_json
      )

      if failed.positive? && ENV["STRICT"] == "1"
        warn "❌ STRICT=1: #{failed} day(s) failed"
        raise "market:fetch_prices failed with #{failed} day(s) in error"
      end

      result
    end
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