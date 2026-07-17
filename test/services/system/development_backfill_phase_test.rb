# frozen_string_literal: true

require "test_helper"

module System
  class DevelopmentBackfillPhaseTest < ActiveSupport::TestCase
    class FakeRedis
      attr_reader :data

      def initialize(data = {})
        @data = data
      end

      def get(key)
        data[key]
      end

      def set(key, value)
        data[key] = value
        "OK"
      end
    end

    test "keeps layer1 priority while layer1 lag is critical" do
      now = Time.zone.parse("2026-07-13 12:00:00")
      redis =
        phase_redis(
          phase: "layer1_catchup",
          changed_at: now - 30.minutes,
          entered_layer1_lag: 12
        )

      with_development_backfill_env(
        "TANSA_BACKFILL_LAYER1_MAX_PHASE_SECONDS" => "60"
      ) do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 12,
            redis: redis,
            now: now
          )

        assert_equal "layer1_catchup", state[:phase]
        assert_equal "hysteresis_hold", state[:reason]
      end
    end

    test "keeps layer1 catchup at lag nine despite exhausted phase budget" do
      now = Time.zone.parse("2026-07-13 12:00:00")
      redis =
        phase_redis(
          phase: "layer1_catchup",
          changed_at: now - 2.minutes,
          entered_layer1_lag: 10
        )

      with_development_backfill_env(
        "TANSA_BACKFILL_LAYER1_MAX_PHASE_SECONDS" => "60"
      ) do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 9,
            redis: redis,
            now: now
          )

        assert_equal "layer1_catchup", state[:phase]
        assert_equal "hysteresis_hold", state[:reason]
        assert_equal 120, state[:phase_elapsed_seconds]
      end
    end

    test "keeps layer1 catchup at lag three despite exhausted phase budget" do
      started_at =
        Time.zone.parse("2026-07-13 12:00:00")

      redis =
        phase_redis(
          phase: "layer1_catchup",
          changed_at: started_at,
          entered_layer1_lag: 10
        )

      with_development_backfill_env(
        "TANSA_BACKFILL_LAYER1_MAX_PHASE_SECONDS" => "60"
      ) do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 3,
            redis: redis,
            now: started_at + 61.seconds
          )

        assert_equal "layer1_catchup", state[:phase]
        assert_equal "hysteresis_hold", state[:reason]
        assert_equal 61, state[:phase_elapsed_seconds]
      end
    end

    test "closes layer1 catchup only at configured stop lag" do
      now = Time.zone.parse("2026-07-13 12:00:00")
      redis =
        phase_redis(
          phase: "layer1_catchup",
          changed_at: now - 30.seconds,
          entered_layer1_lag: 10
        )

      with_development_backfill_env do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 2,
            redis: redis,
            now: now
          )

        assert_equal "downstream_catchup", state[:phase]
        assert_equal "layer1_lag_reached_stop_threshold", state[:reason]
      end
    end

    test "inactive phase stays downstream below start lag" do
      now = Time.zone.parse("2026-07-13 12:00:00")
      redis =
        phase_redis(
          phase: "downstream_catchup",
          changed_at: now - 30.seconds,
          entered_layer1_lag: 1
        )

      with_development_backfill_env do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 9,
            redis: redis,
            now: now
          )

        assert_equal "downstream_catchup", state[:phase]
        assert_equal "hysteresis_hold", state[:reason]
      end
    end

    test "opens layer1 catchup when lag reaches start threshold" do
      now = Time.zone.parse("2026-07-13 12:00:00")
      redis =
        phase_redis(
          phase: "downstream_catchup",
          changed_at: now - 30.seconds,
          entered_layer1_lag: 1
        )

      with_development_backfill_env do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 10,
            redis: redis,
            now: now
          )

        assert_equal "layer1_catchup", state[:phase]
        assert_equal "layer1_lag_reached_start_threshold", state[:reason]
      end
    end

    private

    def phase_redis(phase:, changed_at:, entered_layer1_lag:)
      payload = {
        requested: true,
        enabled: true,
        config_valid: true,
        pipeline_mode: "development_backfill",
        start_lag: 10,
        stop_lag: 2,
        max_layer1_phase_seconds: 60,
        phase: phase,
        changed_at: changed_at.iso8601(6),
        entered_layer1_lag: entered_layer1_lag,
        reason: "hysteresis_hold",
        observed_layer1_lag: entered_layer1_lag
      }

      FakeRedis.new(
        DevelopmentBackfillPhase::STATE_KEY =>
          JSON.generate(payload)
      )
    end

    def with_development_backfill_env(extra = {})
      keys = {
        "TANSA_PIPELINE_MODE" => "development_backfill",
        "TANSA_BACKFILL_ALTERNATING_ENABLED" => "true",
        "TANSA_BACKFILL_LAYER1_START_LAG" => "10",
        "TANSA_BACKFILL_LAYER1_STOP_LAG" => "2"
      }.merge(extra)

      previous =
        keys.keys.to_h do |key|
          [
            key,
            ENV.key?(key) ? ENV[key] : :missing
          ]
        end

      keys.each do |key, value|
        ENV[key] = value
      end

      yield
    ensure
      previous.each do |key, value|
        if value == :missing
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end
  end
end
