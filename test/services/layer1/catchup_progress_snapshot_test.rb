# frozen_string_literal: true

require "test_helper"

module Layer1
  class CatchupProgressSnapshotTest < ActiveSupport::TestCase
    class FakeRedis
      def initialize(data = {})
        @data = data
      end

      def get(key)
        @data[key]
      end

      def set(key, value)
        @data[key] = value
        "OK"
      end
    end

    test "measures Layer1 catchup toward stop lag" do
      started_at = Time.zone.parse("2026-07-08 10:00:00")
      snapshot = Layer1::CatchupProgressSnapshot.call(
        current_lag: 7,
        phase_state: {
          phase: "layer1_catchup",
          changed_at: started_at.iso8601,
          entered_layer1_lag: 10,
          observed_layer1_lag: 7,
          start_lag: 10,
          stop_lag: 2
        },
        redis: FakeRedis.new,
        now: started_at + 30.minutes
      )

      assert_equal 10, snapshot[:baseline_lag]
      assert_equal 3, snapshot[:recovered_blocks]
      assert_equal 5, snapshot[:blocks_to_target]
      assert_equal 2, snapshot[:target_lag]
      assert_equal "catching_up", snapshot[:status]
    end

    test "measures downstream phase toward resume lag" do
      started_at = Time.zone.parse("2026-07-08 11:00:00")
      snapshot = Layer1::CatchupProgressSnapshot.call(
        current_lag: 3,
        phase_state: {
          phase: "downstream_catchup",
          changed_at: started_at.iso8601,
          entered_layer1_lag: 2,
          observed_layer1_lag: 3,
          start_lag: 10,
          stop_lag: 2
        },
        redis: FakeRedis.new,
        now: started_at + 15.minutes
      )

      assert_equal "downstream_catchup", snapshot[:status]
      assert_equal 2, snapshot[:baseline_lag]
      assert_equal 1, snapshot[:accumulated_lag_blocks]
      assert_equal 7, snapshot[:blocks_to_target]
      assert_equal 10, snapshot[:target_lag]
      assert_equal "resume_layer1", snapshot[:target_kind]
    end
  end
end
