# frozen_string_literal: true

require "test_helper"
require "set"

class ExchangeLikeAddressFilterTest < ActiveSupport::TestCase
  setup do
    @filter = ExchangeLike::AddressFilter.new(
      min_occurrences_to_keep: 3,
      min_tx_count_to_keep: 2,
      min_active_days_to_keep: 1
    )
  end

  test "keeps stat when occurrences threshold is reached" do
    stat = {
      occurrences: 3,
      txids: Set.new(["a"]),
      seen_days: Set.new(["2026-04-21"])
    }

    assert @filter.keep?(stat)
  end

  test "keeps stat when tx count threshold is reached" do
    stat = {
      occurrences: 1,
      txids: Set.new(["a", "b"]),
      seen_days: Set.new(["2026-04-21"])
    }

    assert @filter.keep?(stat)
  end

  test "keeps stat when active days threshold is reached and occurrences >= 2" do
    stat = {
      occurrences: 2,
      txids: Set.new(["a"]),
      seen_days: Set.new(["2026-04-21"])
    }

    assert @filter.keep?(stat)
  end

  test "rejects stat when all thresholds fail" do
    stat = {
      occurrences: 1,
      txids: Set.new(["a"]),
      seen_days: Set.new
    }

    assert_not @filter.keep?(stat)
  end
end
