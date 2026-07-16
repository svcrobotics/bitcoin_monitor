# frozen_string_literal: true

require "test_helper"

module Layer1
  class CatchupProgressSnapshotTest < ActiveSupport::TestCase
    class ReadOnlyRedis
      attr_reader :gets

      def initialize(value = nil, error: nil)
        @value = value
        @error = error
        @gets = []
      end

      def get(key)
        gets << key
        raise @error if @error

        @value
      end

      def method_missing(name, ...)
        raise "unexpected Redis mutation #{name}"
      end
    end

    test "measures Layer1 catchup from the canonical persisted phase" do
      now = Time.zone.parse("2026-07-16 12:00:00")
      redis = phase_redis(
        phase: "layer1_catchup",
        changed_at: now - 30.minutes,
        entered_layer1_lag: 10
      )

      snapshot = CatchupProgressSnapshot.call(
        current_lag: 7,
        redis: redis,
        now: now
      )

      assert_equal true, snapshot[:available]
      assert_equal "catching_up", snapshot[:status]
      assert_equal 10, snapshot[:baseline_lag]
      assert_equal 3, snapshot[:recovered_blocks]
      assert_equal 5, snapshot[:blocks_to_target]
      assert_equal 2, snapshot[:target_lag]
      assert_equal [System::DevelopmentBackfillPhase::STATE_KEY], redis.gets
      assert JSON.generate(snapshot)
    end

    test "measures downstream progress toward the start threshold" do
      now = Time.zone.parse("2026-07-16 12:00:00")
      redis = phase_redis(
        phase: "downstream_catchup",
        changed_at: now - 15.minutes,
        entered_layer1_lag: 2
      )

      snapshot = CatchupProgressSnapshot.call(
        current_lag: 3,
        redis: redis,
        now: now
      )

      assert_equal "downstream_catchup", snapshot[:status]
      assert_equal 1, snapshot[:accumulated_lag_blocks]
      assert_equal 7, snapshot[:blocks_to_target]
      assert_equal 10, snapshot[:target_lag]
      assert_equal "resume_layer1", snapshot[:target_kind]
      assert_equal false, snapshot[:estimation_ready]
    end

    test "missing phase state is explicitly unavailable" do
      snapshot = CatchupProgressSnapshot.call(
        current_lag: 4,
        redis: ReadOnlyRedis.new
      )

      assert_unavailable(snapshot, "phase_state_missing")
    end

    test "invalid JSON is explicitly unavailable" do
      snapshot = CatchupProgressSnapshot.call(
        current_lag: 4,
        redis: ReadOnlyRedis.new("not-json")
      )

      assert_unavailable(snapshot, "phase_state_invalid")
    end

    test "invalid phase payload is explicitly unavailable" do
      redis = ReadOnlyRedis.new(
        JSON.generate(
          phase: "unknown",
          changed_at: Time.current.iso8601,
          entered_layer1_lag: 10,
          start_lag: 10,
          stop_lag: 2
        )
      )

      snapshot = CatchupProgressSnapshot.call(current_lag: 4, redis: redis)

      assert_unavailable(snapshot, "phase_state_invalid")
    end

    test "Redis failure is explicit and does not expose an error message" do
      error = Redis::CannotConnectError.new("sensitive endpoint")
      redis = ReadOnlyRedis.new(error: error)

      snapshot = CatchupProgressSnapshot.call(current_lag: 4, redis: redis)

      assert_unavailable(snapshot, "redis_unavailable")
      assert_equal "Redis::CannotConnectError", snapshot[:error_class]
      refute_includes JSON.generate(snapshot), "sensitive endpoint"
    end

    test "unavailable lag fails closed without reading Redis" do
      redis = ReadOnlyRedis.new("unused")

      snapshot = CatchupProgressSnapshot.call(current_lag: nil, redis: redis)

      assert_unavailable(snapshot, "current_lag_unavailable")
      assert_empty redis.gets
    end

    test "implementation only reads the canonical phase key" do
      source = Rails.root.join(
        "app/services/layer1/catchup_progress_snapshot.rb"
      ).read

      assert_match(/System::DevelopmentBackfillPhase::STATE_KEY/, source)
      refute_match(/PHASE_KEY\s*=/, source)
      refute_match(/\.set\(|\.del\(|\.hset\(|perform_(later|async|in)/, source)
    end

    private

    def phase_redis(phase:, changed_at:, entered_layer1_lag:)
      ReadOnlyRedis.new(
        JSON.generate(
          phase: phase,
          changed_at: changed_at.iso8601(6),
          entered_layer1_lag: entered_layer1_lag,
          observed_layer1_lag: entered_layer1_lag,
          start_lag: 10,
          stop_lag: 2
        )
      )
    end

    def assert_unavailable(snapshot, reason)
      assert_equal false, snapshot[:available]
      assert_equal "unavailable", snapshot[:status]
      assert_equal reason, snapshot[:reason]
      assert_nil snapshot[:phase]
      assert_nil snapshot[:observed_change_per_hour]
      assert_nil snapshot[:estimated_catchup_hours]
      assert JSON.generate(snapshot)
    end
  end
end
