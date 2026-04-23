# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Btc
  module Ingestion
    class IntradayBackfillTest < ActiveSupport::TestCase
      test "returns zero when provider returns no candles" do
        Btc::Providers::Intraday::BinanceProvider.stub(
          :fetch_klines,
          []
        ) do
          result = Btc::Ingestion::IntradayBackfill.call(
            market: "btcusd",
            timeframe: "5m",
            limit: 100
          )

          assert_equal 0, result[:fetched]
          assert_equal 0, result[:upserted]
          assert_equal 0, BtcCandle.count
        end
      end

      test "creates candles from provider payload" do
        payload = [
          {
            market: "btcusd",
            timeframe: "5m",
            open_time: Time.zone.parse("2026-04-22 10:00:00"),
            close_time: Time.zone.parse("2026-04-22 10:04:59"),
            open: BigDecimal("78000.0"),
            high: BigDecimal("78100.0"),
            low: BigDecimal("77950.0"),
            close: BigDecimal("78050.0"),
            volume: BigDecimal("12.34"),
            trades_count: 150,
            source: "binance"
          },
          {
            market: "btcusd",
            timeframe: "5m",
            open_time: Time.zone.parse("2026-04-22 10:05:00"),
            close_time: Time.zone.parse("2026-04-22 10:09:59"),
            open: BigDecimal("78050.0"),
            high: BigDecimal("78120.0"),
            low: BigDecimal("78010.0"),
            close: BigDecimal("78110.0"),
            volume: BigDecimal("10.11"),
            trades_count: 120,
            source: "binance"
          }
        ]

        Btc::Providers::Intraday::BinanceProvider.stub(
          :fetch_klines,
          payload
        ) do
          result = Btc::Ingestion::IntradayBackfill.call(
            market: "btcusd",
            timeframe: "5m",
            limit: 100
          )

          assert_equal 2, result[:fetched]
          assert_equal 2, BtcCandle.count

          first = BtcCandle.order(:open_time).first
          second = BtcCandle.order(:open_time).last

          assert_equal "btcusd", first.market
          assert_equal "5m", first.timeframe
          assert_equal Time.zone.parse("2026-04-22 10:00:00"), first.open_time
          assert_equal Time.zone.parse("2026-04-22 10:04:59"), first.close_time
          assert_equal BigDecimal("78000.0"), first.open
          assert_equal BigDecimal("78100.0"), first.high
          assert_equal BigDecimal("77950.0"), first.low
          assert_equal BigDecimal("78050.0"), first.close
          assert_equal BigDecimal("12.34"), first.volume
          assert_equal 150, first.trades_count
          assert_equal "binance", first.source

          assert_equal Time.zone.parse("2026-04-22 10:05:00"), second.open_time
          assert_equal BigDecimal("78110.0"), second.close
        end
      end

      test "upserts existing candles instead of duplicating them" do
        existing_open_time = Time.zone.parse("2026-04-22 10:00:00")
        existing_close_time = Time.zone.parse("2026-04-22 10:04:59")

        BtcCandle.create!(
          market: "btcusd",
          timeframe: "5m",
          open_time: existing_open_time,
          close_time: existing_close_time,
          open: 78000,
          high: 78100,
          low: 77950,
          close: 78050,
          volume: 10.0,
          trades_count: 100,
          source: "seed"
        )

        payload = [
          {
            market: "btcusd",
            timeframe: "5m",
            open_time: existing_open_time,
            close_time: existing_close_time,
            open: BigDecimal("78010.0"),
            high: BigDecimal("78150.0"),
            low: BigDecimal("77900.0"),
            close: BigDecimal("78120.0"),
            volume: BigDecimal("20.5"),
            trades_count: 222,
            source: "binance"
          }
        ]

        Btc::Providers::Intraday::BinanceProvider.stub(
          :fetch_klines,
          payload
        ) do
          result = Btc::Ingestion::IntradayBackfill.call(
            market: "btcusd",
            timeframe: "5m",
            limit: 100
          )

          assert_equal 1, result[:fetched]
          assert_equal 1, BtcCandle.count

          candle = BtcCandle.first
          assert_equal BigDecimal("78010.0"), candle.open
          assert_equal BigDecimal("78150.0"), candle.high
          assert_equal BigDecimal("77900.0"), candle.low
          assert_equal BigDecimal("78120.0"), candle.close
          assert_equal BigDecimal("20.5"), candle.volume
          assert_equal 222, candle.trades_count
          assert_equal "binance", candle.source
        end
      end

      test "passes arguments to provider" do
        captured_args = nil

        fake_provider = lambda do |market:, timeframe:, start_time:, end_time:, limit:|
          captured_args = {
            market: market,
            timeframe: timeframe,
            start_time: start_time,
            end_time: end_time,
            limit: limit
          }
          []
        end

        start_time = Time.zone.parse("2026-04-20 00:00:00")
        end_time = Time.zone.parse("2026-04-21 00:00:00")

        Btc::Providers::Intraday::BinanceProvider.stub(:fetch_klines, fake_provider) do
          Btc::Ingestion::IntradayBackfill.call(
            market: "btceur",
            timeframe: "1h",
            limit: 250,
            start_time: start_time,
            end_time: end_time
          )
        end

        assert_equal "btceur", captured_args[:market]
        assert_equal "1h", captured_args[:timeframe]
        assert_equal 250, captured_args[:limit]
        assert_equal start_time, captured_args[:start_time]
        assert_equal end_time, captured_args[:end_time]
      end
    end
  end
end