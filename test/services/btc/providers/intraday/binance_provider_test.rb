# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Btc
  module Providers
    module Intraday
      class BinanceProviderTest < ActiveSupport::TestCase
        FakeResponse = Struct.new(:body, :code) do
          def is_a?(klass)
            klass == Net::HTTPSuccess
          end
        end

        FakeErrorResponse = Struct.new(:body, :code) do
          def is_a?(klass)
            false
          end
        end

        test "fetch_klines builds request and parses payload" do
          captured_uri = nil

          payload = [
            [
              1_745_308_800_000, # open time ms
              "78000.0",
              "78100.0",
              "77950.0",
              "78050.0",
              "12.34",
              1_745_309_099_000, # close time ms
              "0",
              150,
              "0",
              "0",
              "0"
            ],
            [
              1_745_309_100_000,
              "78050.0",
              "78120.0",
              "78010.0",
              "78110.0",
              "10.11",
              1_745_309_399_000,
              "0",
              120,
              "0",
              "0",
              "0"
            ]
          ]

          fake_http = lambda do |uri|
            captured_uri = uri
            FakeResponse.new(JSON.generate(payload), "200")
          end

          Net::HTTP.stub(:get_response, fake_http) do
            result = Btc::Providers::Intraday::BinanceProvider.fetch_klines(
              market: "btcusd",
              timeframe: "5m",
              limit: 200
            )

            assert_equal 2, result.size

            first = result.first
            assert_equal "btcusd", first[:market]
            assert_equal "5m", first[:timeframe]
            assert_equal Time.at(1_745_308_800).utc, first[:open_time]
            assert_equal Time.at(1_745_309_099).utc, first[:close_time]
            assert_equal BigDecimal("78000.0"), first[:open]
            assert_equal BigDecimal("78100.0"), first[:high]
            assert_equal BigDecimal("77950.0"), first[:low]
            assert_equal BigDecimal("78050.0"), first[:close]
            assert_equal BigDecimal("12.34"), first[:volume]
            assert_equal 150, first[:trades_count]
            assert_equal "binance", first[:source]

            assert_includes captured_uri.to_s, "symbol=BTCUSDT"
            assert_includes captured_uri.to_s, "interval=5m"
            assert_includes captured_uri.to_s, "limit=200"
          end
        end

        test "passes start_time and end_time as milliseconds" do
          captured_uri = nil
          start_time = Time.zone.parse("2026-04-20 00:00:00")
          end_time   = Time.zone.parse("2026-04-21 00:00:00")

          fake_http = lambda do |uri|
            captured_uri = uri
            FakeResponse.new("[]", "200")
          end

          Net::HTTP.stub(:get_response, fake_http) do
            Btc::Providers::Intraday::BinanceProvider.fetch_klines(
              market: "btceur",
              timeframe: "1h",
              start_time: start_time,
              end_time: end_time,
              limit: 50
            )
          end

          assert_includes captured_uri.to_s, "symbol=BTCEUR"
          assert_includes captured_uri.to_s, "interval=1h"
          assert_includes captured_uri.to_s, "limit=50"
          assert_includes captured_uri.to_s, "startTime=#{start_time.to_i * 1000}"
          assert_includes captured_uri.to_s, "endTime=#{end_time.to_i * 1000}"
        end

        test "raises error for unsupported market" do
          error = assert_raises(Btc::Providers::Intraday::BinanceProvider::Error) do
            Btc::Providers::Intraday::BinanceProvider.fetch_klines(
              market: "btcgbp",
              timeframe: "5m",
              limit: 100
            )
          end

          assert_match(/Unsupported market/, error.message)
        end

        test "raises error for unsupported timeframe" do
          error = assert_raises(Btc::Providers::Intraday::BinanceProvider::Error) do
            Btc::Providers::Intraday::BinanceProvider.fetch_klines(
              market: "btcusd",
              timeframe: "2m",
              limit: 100
            )
          end

          assert_match(/Unsupported timeframe/, error.message)
        end

        test "raises error on non success http response" do
          fake_http = lambda do |_uri|
            FakeErrorResponse.new('{"msg":"error"}', "500")
          end

          Net::HTTP.stub(:get_response, fake_http) do
            error = assert_raises(Btc::Providers::Intraday::BinanceProvider::Error) do
              Btc::Providers::Intraday::BinanceProvider.fetch_klines(
                market: "btcusd",
                timeframe: "5m",
                limit: 100
              )
            end

            assert_match(/HTTP 500/, error.message)
          end
        end

        test "raises error when payload is not an array" do
          fake_http = lambda do |_uri|
            FakeResponse.new('{"not":"an array"}', "200")
          end

          Net::HTTP.stub(:get_response, fake_http) do
            error = assert_raises(Btc::Providers::Intraday::BinanceProvider::Error) do
              Btc::Providers::Intraday::BinanceProvider.fetch_klines(
                market: "btcusd",
                timeframe: "5m",
                limit: 100
              )
            end

            assert_match(/Unexpected payload/, error.message)
          end
        end

        test "normalizes limit to maximum 1000" do
          captured_uri = nil

          fake_http = lambda do |uri|
            captured_uri = uri
            FakeResponse.new("[]", "200")
          end

          Net::HTTP.stub(:get_response, fake_http) do
            Btc::Providers::Intraday::BinanceProvider.fetch_klines(
              market: "btcusd",
              timeframe: "5m",
              limit: 5000
            )
          end

          assert_includes captured_uri.to_s, "limit=1000"
        end

        test "normalizes invalid limit to default 500" do
          captured_uri = nil

          fake_http = lambda do |uri|
            captured_uri = uri
            FakeResponse.new("[]", "200")
          end

          Net::HTTP.stub(:get_response, fake_http) do
            Btc::Providers::Intraday::BinanceProvider.fetch_klines(
              market: "btcusd",
              timeframe: "5m",
              limit: 0
            )
          end

          assert_includes captured_uri.to_s, "limit=500"
        end
      end
    end
  end
end