# frozen_string_literal: true

module Btc
  module Cache
    class RecentCandlesCache
      DEFAULT_LIMIT = 120

      class << self
        def refresh(market:, timeframe:, limit: DEFAULT_LIMIT)
          new(market:, timeframe:, limit:).refresh
        end
      end

      def initialize(market:, timeframe:, limit:)
        @market = market
        @timeframe = timeframe
        @limit = limit
      end

      def refresh
        candles = BtcCandle
          .for_market(@market)
          .for_timeframe(@timeframe)
          .recent_first
          .limit(@limit)
          .to_a
          .reverse
          .map do |row|
            {
              time: row.open_time.to_i,
              open: row.open.to_f,
              high: row.high.to_f,
              low: row.low.to_f,
              close: row.close.to_f,
              volume: row.volume&.to_f
            }
          end

        Btc::Cache::Store.write_json(
          Btc::Cache::Keys.candles(market: @market, timeframe: @timeframe, limit: @limit),
          candles,
          expires_in: 5.minutes
        )

        candles
      end
    end
  end
end