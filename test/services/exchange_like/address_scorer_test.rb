# frozen_string_literal: true

require "test_helper"
require "set"

class ExchangeLikeAddressScorerTest < ActiveSupport::TestCase
  setup do
    @scorer = ExchangeLike::AddressScorer.new
  end

  test "returns at least 1" do
    stat = {
      occurrences: 0,
      txids: Set.new,
      seen_days: Set.new,
      total_received_btc: 0.to_d
    }

    assert_equal 1, @scorer.score_increment(stat)
  end

  test "adds volume bonus for 5 btc" do
    stat = {
      occurrences: 1,
      txids: Set.new(["a"]),
      seen_days: Set.new(["2026-04-21"]),
      total_received_btc: 5.to_d
    }

    assert @scorer.score_increment(stat) >= 6
  end

  test "caps score at 100" do
    stat = {
      occurrences: 500,
      txids: Set.new((1..100).map(&:to_s)),
      seen_days: Set.new((1..50).map(&:to_s)),
      total_received_btc: 1000.to_d
    }

    assert_equal 100, @scorer.score_increment(stat)
  end
end
