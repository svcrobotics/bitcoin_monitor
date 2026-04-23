# frozen_string_literal: true

require "test_helper"

module Btc
  class CandlesStatusQueryTest < ActiveSupport::TestCase
    test "returns empty result when no candles exist" do
      result = Btc::CandlesStatusQuery.call(market: "btcusd", timeframe: "5m")

      assert_equal "btcusd", result[:market]
      assert_equal "5m", result[:timeframe]
      assert_nil result[:last_open_time]
      assert_nil result[:last_close_time]
      assert_nil result[:source]
      assert_equal 0, result[:candles_count]
    end

    test "returns latest candle status for market and timeframe" do
      older_open = Time.zone.parse("2026-04-22 10:00:00")
      older_close = Time.zone.parse("2026-04-22 10:04:59")
      newer_open = Time.zone.parse("2026-04-22 10:05:00")
      newer_close = Time.zone.parse("2026-04-22 10:09:59")

      BtcCandle.create!(
        market: "btcusd",
        timeframe: "5m",
        open_time: older_open,
        close_time: older_close,
        open: 78_000,
        high: 78_100,
        low: 77_900,
        close: 78_050,
        volume: 1.2,
        source: "binance"
      )

      BtcCandle.create!(
        market: "btcusd",
        timeframe: "5m",
        open_time: newer_open,
        close_time: newer_close,
        open: 78_050,
        high: 78_120,
        low: 78_000,
        close: 78_090,
        volume: 1.3,
        source: "binance"
      )

      BtcCandle.create!(
        market: "btcusd",
        timeframe: "1h",
        open_time: Time.zone.parse("2026-04-22 10:00:00"),
        close_time: Time.zone.parse("2026-04-22 10:59:59"),
        open: 78_000,
        high: 78_300,
        low: 77_900,
        close: 78_200,
        volume: 10.0,
        source: "binance"
      )

      result = Btc::CandlesStatusQuery.call(market: "btcusd", timeframe: "5m")

      assert_equal "btcusd", result[:market]
      assert_equal "5m", result[:timeframe]
      assert_equal newer_open, result[:last_open_time]
      assert_equal newer_close, result[:last_close_time]
      assert_equal "binance", result[:source]
      assert_equal 2, result[:candles_count]
    end
  end
end