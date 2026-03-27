# frozen_string_literal: true

namespace :btc_price do
  desc "Build BTC daily price rows (default: yesterday) and optionally backfill missing days"
  task daily: :environment do
    # Stratégie: on calcule J-1 par défaut (moins d'API 'close' manquant)
    tz = ActiveSupport::TimeZone[Rails.application.config.time_zone] || Time.zone
    target_day = (tz.now.to_date - 1)

    # Backfill: par défaut 7 jours (modifiable)
    days_back = ENV.fetch("DAYS_BACK", "7").to_i
    days_back = 1 if days_back < 1

    start_day = target_day - (days_back - 1)
    range = (start_day..target_day).to_a

    Rails.logger.info("[btc_price_daily] start target=#{target_day} days_back=#{days_back} range=#{start_day}..#{target_day}")

    ok = 0
    skipped = 0
    failed = 0

    range.each do |day|
      begin
        # Si tu veux “missing only”, décommente:
        # next if BtcPriceDay.exists?(day: day)

        BtcPriceDayBuilder.call(day: day)
        ok += 1
        Rails.logger.info("[btc_price_daily] ok day=#{day}")
      rescue => e
        failed += 1
        Rails.logger.warn("[btc_price_daily] fail day=#{day} #{e.class}: #{e.message}")
      end
    end

    Rails.logger.info("[btc_price_daily] done ok=#{ok} failed=#{failed} skipped=#{skipped}")
  end
end
