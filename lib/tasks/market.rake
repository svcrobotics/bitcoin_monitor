# frozen_string_literal: true

# lib/tasks/market.rake
require "json"

namespace :market do
  desc "Build daily BTC prices (composite: kraken/coinbase/bitstamp) and upsert into btc_price_days"
  task fetch_prices: :environment do
    # Compat: ancien ENV["DAYS"] + nouveau ENV["DAYS_BACK"]
    days_back = (ENV["DAYS_BACK"] || ENV["DAYS"] || "365").to_i
    days_back = 1 if days_back < 1

    # Bougie daily fiable: J-1 par défaut.
    tz = ActiveSupport::TimeZone[Rails.application.config.time_zone] || Time.zone
    target_day = (tz.now.to_date - 1)
    start_day  = target_day - (days_back - 1)

    name = "btc_price_daily"

    JobRun.wrap!(name, meta: { days_back: days_back, start_day: start_day.to_s, target_day: target_day.to_s }) do
      puts "[market:fetch_prices] range=#{start_day}..#{target_day} days_back=#{days_back}"

      ok = 0
      failed = 0
      fails = []

      (start_day..target_day).each do |day|
        begin
          BtcPriceDayBuilder.call(day: day)
          ok += 1
        rescue => e
          failed += 1
          fails << { day: day.to_s, error: "#{e.class}: #{e.message}" }
          warn "[market:fetch_prices] fail day=#{day} #{e.class}: #{e.message}"
          # IMPORTANT: on continue (ne pas crasher toute la tâche)
        end
      end

      result = { ok: ok, failed: failed, range: "#{start_day}..#{target_day}" }
      puts "✅ OK: #{result.inspect}"

      # bonus: enrich meta si la colonne existe (wrap! la met au départ)
      if JobRun.column_names.include?("meta")
        jr = JobRun.for_job(name).recent.first
        if jr
          meta_hash =
            case jr.meta
            when String then (JSON.parse(jr.meta) rescue {})
            when Hash   then jr.meta
            else {}
            end

          meta_hash["result"] = result
          meta_hash["fails"]  = fails if fails.any?

          # Jr.meta peut être json string ou jsonb selon DB → on stocke en json string propre
          jr.update!(meta: meta_hash.to_json)
        end
      end

      # Option strict: fais échouer la tâche si on a au moins 1 fail
      if failed.positive? && ENV["STRICT"] == "1"
        warn "❌ STRICT=1: #{failed} day(s) failed"
        exit 1
      end
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
