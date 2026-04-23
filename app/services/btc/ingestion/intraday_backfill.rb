# app/services/btc/ingestion/intraday_backfill.rb
# frozen_string_literal: true

module Btc
  module Ingestion
    class IntradayBackfill
      DEFAULT_LIMIT = 500

      class << self
        def call(market:, timeframe:, limit: DEFAULT_LIMIT, start_time: nil, end_time: nil)
          new(
            market: market,
            timeframe: timeframe,
            limit: limit,
            start_time: start_time,
            end_time: end_time
          ).call
        end
      end

      def initialize(market:, timeframe:, limit:, start_time:, end_time:)
        @market = market
        @timeframe = timeframe
        @limit = limit
        @start_time = start_time
        @end_time = end_time
      end

      def call
        candles = Btc::Providers::Intraday::BinanceProvider.fetch_klines(
          market: @market,
          timeframe: @timeframe,
          start_time: @start_time,
          end_time: @end_time,
          limit: @limit
        )

        return { fetched: 0, upserted: 0 } if candles.empty?

        attrs = candles.map do |candle|
          {
            market: candle[:market],
            timeframe: candle[:timeframe],
            open_time: candle[:open_time],
            close_time: candle[:close_time],
            open: candle[:open],
            high: candle[:high],
            low: candle[:low],
            close: candle[:close],
            volume: candle[:volume],
            trades_count: candle[:trades_count],
            source: candle[:source],
            created_at: Time.current,
            updated_at: Time.current
          }
        end

        result = BtcCandle.upsert_all(
          attrs,
          unique_by: %i[market timeframe open_time]
        )

        Btc::Cache::RecentCandlesCache.refresh(
          market: @market,
          timeframe: @timeframe,
          limit: 120
        )

        Btc::Cache::CandlesStatusCache.refresh(
          market: @market,
          timeframe: @timeframe
        )

        Btc::Cache::SummaryCache.refresh(market: @market) if @market == "btcusd"

        {
          fetched: candles.size,
          upserted: attrs.size
        }
      end
    end
  end
end