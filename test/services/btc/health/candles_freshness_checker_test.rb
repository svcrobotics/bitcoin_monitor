# frozen_string_literal: true

require "test_helper"

module Btc
  module Health
    class CandlesFreshnessCheckerTest < ActiveSupport::TestCase
      test "returns offline when last_close_time is blank" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: nil,
          timeframe: "5m"
        )

        assert_equal "offline", result
      end

      test "returns fresh for recent 5m candle" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: 5.minutes.ago,
          timeframe: "5m"
        )

        assert_equal "fresh", result
      end

      test "returns delayed for moderately old 5m candle" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: 15.minutes.ago,
          timeframe: "5m"
        )

        assert_equal "delayed", result
      end

      test "returns stale for old 5m candle" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: 40.minutes.ago,
          timeframe: "5m"
        )

        assert_equal "stale", result
      end

      test "returns fresh for recent 1h candle" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: 90.minutes.ago,
          timeframe: "1h"
        )

        assert_equal "fresh", result
      end

      test "returns delayed for moderately old 1h candle" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: 3.hours.ago,
          timeframe: "1h"
        )

        assert_equal "delayed", result
      end

      test "returns stale for old 1h candle" do
        result = Btc::Health::CandlesFreshnessChecker.call(
          last_close_time: 6.hours.ago,
          timeframe: "1h"
        )

        assert_equal "stale", result
      end
    end
  end
end