# frozen_string_literal: true

module Btc
  class CandlesQuery
    DEFAULT_MARKET = "btcusd"
    DEFAULT_TIMEFRAME = "1h"
    DEFAULT_LIMIT = 120
    CACHE_TTL = 5.minutes

    class << self
      def call(market: DEFAULT_MARKET, timeframe: DEFAULT_TIMEFRAME, limit: DEFAULT_LIMIT)
        new(market:, timeframe:, limit:).call
      end
    end

    def initialize(market:, timeframe:, limit:)
      @market = market.presence || DEFAULT_MARKET
      @timeframe = timeframe.presence || DEFAULT_TIMEFRAME
      @limit = normalize_limit(limit)
    end

    def call
      key = Btc::Cache::Keys.candles(
        market: @market,
        timeframe: @timeframe,
        limit: @limit
      )

      Btc::Cache::Store.fetch_json(key, expires_in: CACHE_TTL) do
        build_candles
      end
    end

    private

    def build_candles
      rows = BtcCandle
        .for_market(@market)
        .for_timeframe(@timeframe)
        .recent_first
        .limit(@limit)
        .to_a
        .reverse

      rows.map do |row|
        {
          time: row.open_time.to_i,
          open: row.open.to_f,
          high: row.high.to_f,
          low: row.low.to_f,
          close: row.close.to_f,
          volume: row.volume&.to_f
        }
      end
    end

    def normalize_limit(limit)
      value = limit.to_i
      return DEFAULT_LIMIT if value <= 0

      [value, 500].min
    end
  end
end