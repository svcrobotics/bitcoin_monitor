# frozen_string_literal: true

module Btc
  class SummaryQuery
    CACHE_TTL = 5.minutes

    class << self
      def call(market: "btcusd")
        new(market: market).call
      end
    end

    def initialize(market: "btcusd")
      @market = market
    end

    def call
      key = Btc::Cache::Keys.summary(market: @market)

      Btc::Cache::Store.fetch_json(key, expires_in: CACHE_TTL) do
        build_summary
      end
    end

    private

    def build_summary
      latest_snapshot = MarketSnapshot.latest_ok
      latest_price = latest_daily_price

      return empty_result unless latest_price

      previous_price = previous_daily_price(before_day: latest_price[:day])

      {
        day: latest_price[:day],
        close_usd: latest_price[:close_usd],
        source: latest_price[:source],
        price_now_usd: latest_snapshot&.price_now_usd&.to_f || latest_price[:close_usd],
        daily_change_pct: compute_daily_change_pct(previous_price&.dig(:close_usd), latest_price[:close_usd]),
        ma200_usd: latest_snapshot&.ma200_usd&.to_f,
        ath_usd: latest_snapshot&.ath_usd&.to_f,
        drawdown_pct: latest_snapshot&.drawdown_pct&.to_f,
        amplitude_30d_pct: latest_snapshot&.amplitude_30d_pct&.to_f,
        price_vs_ma200_pct: latest_snapshot&.price_vs_ma200_pct&.to_f,
        market_bias: latest_snapshot&.market_bias,
        cycle_zone: latest_snapshot&.cycle_zone,
        risk_level: latest_snapshot&.risk_level,
        updated_at: (latest_snapshot&.computed_at || latest_price[:day].to_time)&.iso8601
      }
    end

    def latest_daily_price
      Btc::DailyHistoryQuery.call(range: "7d").last || latest_daily_fallback
    end

    def latest_daily_fallback
      row = BtcPriceDay.with_close.order(day: :desc).pluck(:day, :close_usd, :source).first
      return nil unless row

      { day: row[0], close_usd: row[1].to_f, source: row[2] }
    end

    def previous_daily_price(before_day:)
      row = BtcPriceDay.with_close.where("day < ?", before_day).order(day: :desc).pluck(:day, :close_usd, :source).first
      return nil unless row

      { day: row[0], close_usd: row[1].to_f, source: row[2] }
    end

    def compute_daily_change_pct(previous_close, current_close)
      return nil if previous_close.blank? || current_close.blank?
      return nil if previous_close.to_f.zero?

      (((current_close.to_f - previous_close.to_f) / previous_close.to_f) * 100.0).round(2)
    end

    def empty_result
      {
        day: nil,
        close_usd: nil,
        source: nil,
        price_now_usd: nil,
        daily_change_pct: nil,
        ma200_usd: nil,
        ath_usd: nil,
        drawdown_pct: nil,
        amplitude_30d_pct: nil,
        price_vs_ma200_pct: nil,
        market_bias: nil,
        cycle_zone: nil,
        risk_level: nil,
        updated_at: nil
      }
    end
  end
end