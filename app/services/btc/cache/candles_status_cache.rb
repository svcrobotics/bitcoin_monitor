# frozen_string_literal: true

module Btc
  module Cache
    class CandlesStatusCache
      class << self
        def refresh(market:, timeframe:)
          new(market:, timeframe:).refresh
        end
      end

      def initialize(market:, timeframe:)
        @market = market
        @timeframe = timeframe
      end

      def refresh
        relation = BtcCandle.for_market(@market).for_timeframe(@timeframe)
        last_candle = relation.recent_first.first

        payload =
          if last_candle
            {
              market: @market,
              timeframe: @timeframe,
              last_open_time: last_candle.open_time.iso8601,
              last_close_time: last_candle.close_time.iso8601,
              source: last_candle.source,
              candles_count: relation.count
            }
          else
            {
              market: @market,
              timeframe: @timeframe,
              last_open_time: nil,
              last_close_time: nil,
              source: nil,
              candles_count: 0
            }
          end

        Btc::Cache::Store.write_json(
          Btc::Cache::Keys.candles_status(market: @market, timeframe: @timeframe),
          payload,
          expires_in: 5.minutes
        )

        payload
      end
    end
  end
end