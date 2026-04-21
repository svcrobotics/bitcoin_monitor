# frozen_string_literal: true

require "test_helper"

class ExchangeLikeSummaryQueryTest < ActiveSupport::TestCase
  test "returns expected keys" do
    result = ExchangeLike::SummaryQuery.new.call

    assert_includes result.keys, :addresses_total
    assert_includes result.keys, :addresses_operational
    assert_includes result.keys, :addresses_scannable
    assert_includes result.keys, :observed_total
    assert_includes result.keys, :new_addresses_24h
    assert_includes result.keys, :seen_24h
    assert_includes result.keys, :spent_24h
  end
end
