# frozen_string_literal: true

require "test_helper"

module Btc
  class CandlesQueryTest < ActiveSupport::TestCase
    test "returns candles ordered by open_time ascending" do
      BtcCandle.create!(
        market: "btcusd",
        timeframe: "1h",
        open_time: Time.zone.parse("2026-04-22 10:00:00"),
        close_time: Time.zone.parse("2026-04-22 10:59:59"),
        open: 78_000,
        high: 78_300,
        low: 77_900,
        close: 78_100,
        volume: 10.5,
        source: "binance"
      )

      BtcCandle.create!(
        market: "btcusd",
        timeframe: "1h",
        open_time: Time.zone.parse("2026-04-22 11:00:00"),
        close_time: Time.zone.parse("2026-04-22 11:59:59"),
        open: 78_100,
        high: 78_400,
        low: 78_000,
        close: 78_200,
        volume: 11.0,
        source: "binance"
      )

      result = Btc::CandlesQuery.call(market: "btcusd", timeframe: "1h", limit: 10)

      assert_equal 2, result.size
      assert_equal Time.zone.parse("2026-04-22 10:00:00").to_i, result[0][:time]
      assert_equal 78_000.0, result[0][:open]
      assert_equal Time.zone.parse("2026-04-22 11:00:00").to_i, result[1][:time]
      assert_equal 78_200.0, result[1][:close]
    end

    test "filters by market and timeframe" do
      BtcCandle.create!(
        market: "btcusd",
        timeframe: "5m",
        open_time: Time.zone.parse("2026-04-22 10:00:00"),
        close_time: Time.zone.parse("2026-04-22 10:04:59"),
        open: 78_000,
        high: 78_020,
        low: 77_980,
        close: 78_010,
        volume: 1.1,
        source: "binance"
      )

      BtcCandle.create!(
        market: "btceur",
        timeframe: "5m",
        open_time: Time.zone.parse("2026-04-22 10:00:00"),
        close_time: Time.zone.parse("2026-04-22 10:04:59"),
        open: 72_000,
        high: 72_020,
        low: 71_980,
        close: 72_010,
        volume: 1.2,
        source: "binance"
      )

      result = Btc::CandlesQuery.call(market: "btcusd", timeframe: "5m", limit: 10)

      assert_equal 1, result.size
      assert_equal 78_010.0, result.first[:close]
    end

    test "respects limit" do
      3.times do |i|
        BtcCandle.create!(
          market: "btcusd",
          timeframe: "1h",
          open_time: Time.zone.parse("2026-04-22 #{10 + i}:00:00"),
          close_time: Time.zone.parse("2026-04-22 #{10 + i}:59:59"),
          open: 78_000 + i,
          high: 78_100 + i,
          low: 77_900 + i,
          close: 78_050 + i,
          volume: 5 + i,
          source: "binance"
        )
      end

      result = Btc::CandlesQuery.call(market: "btcusd", timeframe: "1h", limit: 2)

      assert_equal 2, result.size
      assert_equal Time.zone.parse("2026-04-22 11:00:00").to_i, result[0][:time]
      assert_equal Time.zone.parse("2026-04-22 12:00:00").to_i, result[1][:time]
    end
  end
end