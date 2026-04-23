# frozen_string_literal: true

require "test_helper"

module Btc
  class PeriodMetricsQueryTest < ActiveSupport::TestCase
    test "returns empty result when history has less than two points" do
      result = Btc::PeriodMetricsQuery.call(
        history: [
          { day: Date.current - 1, close_usd: 80_000.0 }
        ]
      )

      assert_nil result[:perf_pct]
      assert_nil result[:high]
      assert_nil result[:low]
      assert_nil result[:pos_pct]
      assert_nil result[:max_drawdown_pct]
      assert_nil result[:vol_pct]
      assert_nil result[:vol_label]
    end

    test "computes period metrics correctly" do
      history = [
        { day: Date.current - 4, close_usd: 100.0 },
        { day: Date.current - 3, close_usd: 120.0 },
        { day: Date.current - 2, close_usd: 90.0 },
        { day: Date.current - 1, close_usd: 110.0 }
      ]

      result = Btc::PeriodMetricsQuery.call(history: history)

      assert_equal 10.0, result[:perf_pct]
      assert_equal 120.0, result[:high]
      assert_equal 90.0, result[:low]
      assert_equal 67, result[:pos_pct]
      assert_equal(-25.0, result[:max_drawdown_pct])
      assert_in_delta 22.41, result[:vol_pct], 0.01
      assert_equal "Élevée", result[:vol_label]
    end

    test "returns medium volatility label when vol is moderate" do
      history = [
        { day: Date.current - 3, close_usd: 100.0 },
        { day: Date.current - 2, close_usd: 102.0 },
        { day: Date.current - 1, close_usd: 104.1 }
      ]

      result = Btc::PeriodMetricsQuery.call(history: history)

      assert_equal "Moyenne", result[:vol_label]
    end

    test "returns low volatility label when vol is small" do
      history = [
        { day: Date.current - 3, close_usd: 100.0 },
        { day: Date.current - 2, close_usd: 100.8 },
        { day: Date.current - 1, close_usd: 101.3 }
      ]

      result = Btc::PeriodMetricsQuery.call(history: history)

      assert_equal "Faible", result[:vol_label]
    end
  end
end