# frozen_string_literal: true

require "test_helper"

module Btc
  class DailyHistoryQueryTest < ActiveSupport::TestCase
    test "returns chosen rows ordered by day ascending" do
      day_1 = Date.current - 3
      day_2 = Date.current - 2

      BtcPriceDay.create!(
        day: day_1,
        close_usd: 84_100,
        source: "composite"
      )

      BtcPriceDay.create!(
        day: day_2,
        close_usd: 85_000,
        source: "composite"
      )

      result = Btc::DailyHistoryQuery.call(range: "30d")

      assert_equal 2, result.size
      assert_equal day_1, result[0][:day]
      assert_equal 84_100.0, result[0][:close_usd]
      assert_equal "composite", result[0][:source]

      assert_equal day_2, result[1][:day]
      assert_equal 85_000.0, result[1][:close_usd]
      assert_equal "composite", result[1][:source]
    end

    test "returns one row when only one day exists" do
      day = Date.current - 2

      BtcPriceDay.create!(
        day: day,
        close_usd: 82_700,
        source: "coingecko"
      )

      result = Btc::DailyHistoryQuery.call(range: "30d")

      assert_equal 1, result.size
      assert_equal day, result.first[:day]
      assert_equal 82_700.0, result.first[:close_usd]
      assert_equal "coingecko", result.first[:source]
    end

    test "returns empty array when no rows exist in range" do
      result = Btc::DailyHistoryQuery.call(range: "7d")
      assert_equal [], result
    end
  end
end