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

    test "keeps layer1 priority for every positive lag" do
      now = Time.zone.parse("2026-07-13 12:00:00")

      [ 1, 2, 4, 9, 100 ].each do |lag|
        redis =
          phase_redis(
            phase: "downstream_catchup",
            changed_at: now - 30.seconds,
            entered_layer1_lag: 0
          )

        with_development_backfill_env do
          state =
            DevelopmentBackfillPhase.resolve(
              layer1_lag: lag,
              redis: redis,
              now: now
            )

          assert_equal "layer1_catchup", state[:phase],
                       "expected Layer1 priority at lag #{lag}"
          assert_equal "layer1_lag_detected", state[:reason]
        end
      end
    end

    test "continues layer1 catchup below legacy thresholds" do
      now = Time.zone.parse("2026-07-13 12:00:00")
      redis =
        phase_redis(
          phase: "layer1_catchup",
          changed_at: now - 2.minutes,
          entered_layer1_lag: 10
        )

      with_development_backfill_env do
        state =
          DevelopmentBackfillPhase.resolve(
            layer1_lag: 2,
            redis: redis,
            now: now
          )

        assert_equal "layer1_catchup", state[:phase]
        assert_equal "layer1_continuous_catchup", state[:reason]
        assert_equal 120, state[:phase_elapsed_seconds]
      end
    end

    test "releases layer1 priority only at lag zero" do
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
            layer1_lag: 0,
            redis: redis,
            now: now
          )

        assert_equal "downstream_catchup", state[:phase]
        assert_equal "layer1_caught_up", state[:reason]
      end
    end

    test "stays downstream while layer1 is caught up" do
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
            layer1_lag: 0,
            redis: redis,
            now: now
          )

        assert_equal "downstream_catchup", state[:phase]
        assert_equal "layer1_caught_up", state[:reason]
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
