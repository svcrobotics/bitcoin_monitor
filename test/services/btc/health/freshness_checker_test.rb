# frozen_string_literal: true

require "test_helper"

module Btc
  module Health
    class FreshnessCheckerTest < ActiveSupport::TestCase
      test "returns offline when timestamp is blank" do
        assert_equal "offline", Btc::Health::FreshnessChecker.call(nil)
      end

      test "returns fresh when timestamp is recent" do
        timestamp = 6.hours.ago
        assert_equal "fresh", Btc::Health::FreshnessChecker.call(timestamp)
      end

      test "returns delayed when timestamp is between 24h and 48h" do
        timestamp = 30.hours.ago
        assert_equal "delayed", Btc::Health::FreshnessChecker.call(timestamp)
      end

      test "returns stale when timestamp is older than 48h" do
        timestamp = 72.hours.ago
        assert_equal "stale", Btc::Health::FreshnessChecker.call(timestamp)
      end
    end
  end
end