# frozen_string_literal: true

require "test_helper"

module System
  class DevelopmentBackfillPhaseTest < ActiveSupport::TestCase
    class FakeRedis
      attr_reader :data, :gets, :sets

      def initialize(data = {})
        @data = data
        @gets = []
        @sets = []
      end

      def get(key)
        gets << key
        data[key]
      end

      def set(key, value)
        sets << [key, value]
        data[key] = value
        "OK"
      end
    end

    test "resolves and persists the enabled hysteresis phase through the injected Redis adapter" do
      now = Time.zone.parse("2026-07-16 12:00:00")
      redis = phase_redis(
        phase: "downstream_catchup",
        changed_at: now - 30.seconds,
        entered_layer1_lag: 1
      )

      with_backfill_env do
        result = DevelopmentBackfillPhase.resolve(
          layer1_lag: 10,
          redis: redis,
          now: now
        )

        assert_equal "layer1_catchup", result[:phase]
        assert_equal "layer1_lag_reached_start_threshold", result[:reason]
        assert_equal [DevelopmentBackfillPhase::STATE_KEY], redis.gets
        assert_equal 1, redis.sets.size
        assert_equal DevelopmentBackfillPhase::STATE_KEY, redis.sets.first.first
        assert_equal result.stringify_keys, JSON.parse(redis.sets.first.last)
        assert JSON.generate(result)
      end
    end

    test "holds the current phase inside the configured hysteresis window" do
      now = Time.zone.parse("2026-07-16 12:00:00")
      redis = phase_redis(
        phase: "layer1_catchup",
        changed_at: now - 2.minutes,
        entered_layer1_lag: 10
      )

      with_backfill_env do
        result = DevelopmentBackfillPhase.resolve(
          layer1_lag: 3,
          redis: redis,
          now: now
        )

        assert_equal "layer1_catchup", result[:phase]
        assert_equal "hysteresis_hold", result[:reason]
        assert_equal 120, result[:phase_elapsed_seconds]
      end
    end

    test "disabled and invalid configurations fail closed without touching Redis" do
      redis = FakeRedis.new

      with_backfill_env("TANSA_BACKFILL_ALTERNATING_ENABLED" => "false") do
        result = DevelopmentBackfillPhase.resolve(layer1_lag: 100, redis: redis)
        assert_equal false, result[:enabled]
        assert_nil result[:phase]
        assert_equal "alternating_backfill_disabled", result[:reason]
      end

      with_backfill_env("TANSA_BACKFILL_LAYER1_START_LAG" => "invalid") do
        result = DevelopmentBackfillPhase.resolve(layer1_lag: 100, redis: redis)
        assert_equal false, result[:enabled]
        assert_equal false, result[:config_valid]
        assert_nil result[:phase]
        assert_equal "invalid_configuration", result[:reason]
      end

      assert_empty redis.gets
      assert_empty redis.sets
    end

    test "unavailable lag remains fail closed and does not mutate the operational phase" do
      now = Time.zone.parse("2026-07-16 12:00:00")
      redis = phase_redis(
        phase: "downstream_catchup",
        changed_at: now - 1.minute,
        entered_layer1_lag: 1
      )

      with_backfill_env do
        result = DevelopmentBackfillPhase.resolve(
          layer1_lag: nil,
          redis: redis,
          now: now
        )

        assert_equal "downstream_catchup", result[:phase]
        assert_equal "layer1_lag_unavailable", result[:reason]
        assert_nil result[:observed_layer1_lag]
        assert_equal [DevelopmentBackfillPhase::STATE_KEY], redis.gets
        assert_empty redis.sets
        assert JSON.generate(result)
      end
    end

    test "Redis failure returns an explicit fail-closed serializable payload" do
      redis = Object.new
      redis.define_singleton_method(:get) { |_| raise Redis::CannotConnectError, "offline" }

      with_backfill_env do
        result = DevelopmentBackfillPhase.resolve(layer1_lag: 12, redis: redis)

        assert_nil result[:phase]
        assert_equal "phase_resolution_failed", result[:reason]
        assert_match(/Redis::CannotConnectError/, result[:error])
        assert JSON.generate(result)
      end
    end

    test "PipelineController snapshot delegates phase resolution with its Redis adapter" do
      fake_redis = FakeRedis.new
      fake_redis.define_singleton_method(:llen) { |_| 0 }
      bitcoin_rpc = Object.new
      bitcoin_rpc.define_singleton_method(:getblockcount) { 100 }
      block_scope = ->(status) do
        Object.new.tap do |scope|
          scope.define_singleton_method(:maximum) { |_| status == "processed" ? 98 : nil }
          scope.define_singleton_method(:minimum) { |_| nil }
        end
      end
      cluster_scope = ->(status) do
        Object.new.tap do |scope|
          scope.define_singleton_method(:maximum) { |_| status == "processed" ? 98 : nil }
          scope.define_singleton_method(:minimum) { |_| nil }
        end
      end
      calls = []
      resolver = ->(**options) do
        calls << options
        { enabled: true, config_valid: true, phase: "downstream_catchup" }
      end
      strict_io_lease = Class.new do
        def self.current
          nil
        end
      end

      with_temporary_constant(StrictPipeline, :StrictIoLease, strict_io_lease) do
        with_singleton_method(Redis, :new, ->(*) { fake_redis }) do
          with_singleton_method(BitcoinRpc, :new, ->(*) { bitcoin_rpc }) do
            with_singleton_method(BlockBufferModel, :where, ->(status:) { block_scope.call(status) }) do
              with_singleton_method(ClusterProcessedBlock, :where, ->(status:) { cluster_scope.call(status) }) do
                with_singleton_method(DevelopmentBackfillPhase, :resolve, resolver) do
                  with_singleton_method(PipelineController, :sidekiq_queue_size, ->(*) { 0 }) do
                    with_singleton_method(PipelineController, :sidekiq_worker_busy?, ->(*) { false }) do
                      with_singleton_method(PipelineController, :sidekiq_work_active?, ->(*) { false }) do
                        with_singleton_method(PipelineController, :address_spend_projection_snapshot, ->(*) { {} }) do
                          with_singleton_method(PipelineController, :actor_profile_snapshot, ->(*) { {} }) do
                            with_singleton_method(PipelineController, :actor_labels_snapshot, ->(*) { {} }) do
                              result = PipelineController.snapshot
                              assert_equal "downstream_catchup", result.dig(:development_backfill, :phase)
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      assert_equal 1, calls.size
      assert_equal 2, calls.first[:layer1_lag]
      assert_same fake_redis, calls.first[:redis]
    end

    private

    def with_singleton_method(target, name, replacement)
      original = target.method(name)
      target.define_singleton_method(name, replacement)
      yield
    ensure
      target.define_singleton_method(name, original)
    end

    def with_temporary_constant(namespace, name, value)
      existed = namespace.const_defined?(name, false)
      original = namespace.const_get(name, false) if existed
      namespace.send(:remove_const, name) if existed
      namespace.const_set(name, value)
      yield
    ensure
      namespace.send(:remove_const, name) if namespace.const_defined?(name, false)
      namespace.const_set(name, original) if existed
    end

    def phase_redis(phase:, changed_at:, entered_layer1_lag:)
      payload = {
        phase: phase,
        changed_at: changed_at.iso8601(6),
        entered_layer1_lag: entered_layer1_lag
      }

      FakeRedis.new(
        DevelopmentBackfillPhase::STATE_KEY => JSON.generate(payload)
      )
    end

    def with_backfill_env(overrides = {})
      values = {
        "TANSA_PIPELINE_MODE" => "development_backfill",
        "TANSA_BACKFILL_ALTERNATING_ENABLED" => "true",
        "TANSA_BACKFILL_LAYER1_START_LAG" => "10",
        "TANSA_BACKFILL_LAYER1_STOP_LAG" => "2",
        "TANSA_BACKFILL_LAYER1_MAX_PHASE_SECONDS" => "900"
      }.merge(overrides)
      previous = values.to_h { |key, _| [key, ENV.key?(key) ? ENV[key] : :missing] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each do |key, value|
        value == :missing ? ENV.delete(key) : ENV[key] = value
      end
    end
  end
end
