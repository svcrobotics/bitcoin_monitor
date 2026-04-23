# frozen_string_literal: true

require "test_helper"

module Btc
  class SummaryQueryTest < ActiveSupport::TestCase
    test "returns empty result when no price data exists" do
      result = Btc::SummaryQuery.call

      assert_nil result[:day]
      assert_nil result[:close_usd]
      assert_nil result[:price_now_usd]
      assert_nil result[:daily_change_pct]
      assert_nil result[:ma200_usd]
      assert_nil result[:ath_usd]
      assert_nil result[:drawdown_pct]
      assert_nil result[:updated_at]
    end

    test "returns latest price data without snapshot" do
      day_1 = Date.current - 3
      day_2 = Date.current - 2

      BtcPriceDay.create!(day: day_1, close_usd: 80_000, source: "composite")
      BtcPriceDay.create!(day: day_2, close_usd: 82_000, source: "composite")

      result = Btc::SummaryQuery.call

      assert_equal day_2, result[:day]
      assert_equal 82_000.0, result[:close_usd]
      assert_equal 82_000.0, result[:price_now_usd]
      assert_equal 2.5, result[:daily_change_pct]
      assert_equal "composite", result[:source]
      assert_not_nil result[:updated_at]
    end

    test "uses latest ok snapshot when present" do
      day_1 = Date.current - 3
      day_2 = Date.current - 2

      BtcPriceDay.create!(day: day_1, close_usd: 80_000, source: "composite")
      BtcPriceDay.create!(day: day_2, close_usd: 82_000, source: "composite")

      MarketSnapshot.create!(
        computed_at: 2.hours.ago,
        price_now_usd: 82_500,
        ma200_usd: 64_000,
        price_vs_ma200_pct: 28.91,
        ath_usd: 109_000,
        drawdown_pct: -24.31,
        amplitude_30d_pct: 11.75,
        market_bias: "bull",
        cycle_zone: "mid",
        risk_level: "medium",
        reasons: ["test"],
        status: "ok",
        error_message: nil
      )

      result = Btc::SummaryQuery.call

      assert_equal day_2, result[:day]
      assert_equal 82_000.0, result[:close_usd]
      assert_equal 82_500.0, result[:price_now_usd]
      assert_equal 64_000.0, result[:ma200_usd]
      assert_equal 109_000.0, result[:ath_usd]
      assert_equal(-24.31, result[:drawdown_pct])
      assert_equal 11.75, result[:amplitude_30d_pct]
      assert_equal 28.91, result[:price_vs_ma200_pct]
      assert_equal "bull", result[:market_bias]
      assert_equal "mid", result[:cycle_zone]
      assert_equal "medium", result[:risk_level]
    end

    test "ignores snapshot in error status" do
      day_1 = Date.current - 3
      day_2 = Date.current - 2

      BtcPriceDay.create!(day: day_1, close_usd: 80_000, source: "composite")
      BtcPriceDay.create!(day: day_2, close_usd: 82_000, source: "composite")

      MarketSnapshot.create!(
        computed_at: 2.hours.ago,
        price_now_usd: 99_999,
        ma200_usd: 99_999,
        price_vs_ma200_pct: 99.99,
        ath_usd: 99_999,
        drawdown_pct: -1.0,
        amplitude_30d_pct: 1.0,
        market_bias: "bull",
        cycle_zone: "near_ath",
        risk_level: "low",
        reasons: ["test"],
        status: "error",
        error_message: "boom"
      )

      result = Btc::SummaryQuery.call

      assert_equal 82_000.0, result[:price_now_usd]
      assert_nil result[:ma200_usd]
      assert_nil result[:ath_usd]
      assert_nil result[:drawdown_pct]
    end
  end
end