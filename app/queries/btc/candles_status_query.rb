# frozen_string_literal: true

module Btc
  class CandlesStatusQuery
    CACHE_TTL = 5.minutes

    class << self
      def call(market:, timeframe:)
        new(market:, timeframe:).call
      end
    end

    def initialize(market:, timeframe:)
      @market = market
      @timeframe = timeframe
    end

    def call
      key = Btc::Cache::Keys.candles_status(
        market: @market,
        timeframe: @timeframe
      )

      Btc::Cache::Store.fetch_json(key, expires_in: CACHE_TTL) do
        build_status
      end
    end

    private

    def build_status
      relation = BtcCandle.for_market(@market).for_timeframe(@timeframe)
      last_candle = relation.recent_first.first

      return empty_result unless last_candle

      {
        market: @market,
        timeframe: @timeframe,
        last_open_time: last_candle.open_time.iso8601,
        last_close_time: last_candle.close_time.iso8601,
        source: last_candle.source,
        candles_count: relation.count
      }
    end

    def empty_result
      {
        market: @market,
        timeframe: @timeframe,
        last_open_time: nil,
        last_close_time: nil,
        source: nil,
        candles_count: 0
      }
    end
  end
end