# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Layer1
  module Realtime
    class HealthSnapshotTest < ActiveSupport::TestCase
      class FakeRedis
        attr_reader :data

        def initialize(data = {})
          @data = data
        end

        def llen(_key)
          0
        end

        def exists?(_key)
          false
        end

        def ttl(_key)
          -2
        end

        def get(key)
          data[key]
        end

        def set(key, value)
          data[key] = value
          "OK"
        end

        def del(key)
          data.delete(key)
          1
        end
      end

      test "legacy health snapshot delegates to realtime" do
        expected = {
          status: "healthy",
          processed_height: 956_250,
          lag: 0
        }

        original_call =
          Layer1::Realtime::HealthSnapshot.method(:call)

        Layer1::Realtime::HealthSnapshot
          .define_singleton_method(:call) do
            expected
          end

        assert_equal expected, Layer1::HealthSnapshot.call
      ensure
        Layer1::Realtime::HealthSnapshot
          .define_singleton_method(
            :call,
            original_call
          )
      end

      test "realtime snapshot does not depend on historical projection state" do
        BlockBufferModel.create!(
          height: 956_250,
          block_hash: "1" * 64,
          status: "processed",
          tx_count: 1,
          processed_at: Time.current
        )

        service = Layer1::Realtime::HealthSnapshot.new

        service.define_singleton_method(:bitcoin_core_tip) do
          [956_250, nil]
        end

        service.define_singleton_method(:strict_worker_process) do
          { present: true, busy: 0, process_count: 1 }
        end

        service.define_singleton_method(:strict_scheduler_snapshot) do
          { registered: true, enabled: true }
        end

        service.define_singleton_method(:queue_process) do |_queue_name|
          { present: true, busy: 0, process_count: 1 }
        end

        with_stubbed(Redis, :new, FakeRedis.new) do
          with_stubbed(
            Layer1::TxOutputsSpentSync::OperationalSnapshot,
            :call,
            ->(*) { raise "historical projection unavailable" }
          ) do
            snapshot = service.call

            assert_equal "healthy", snapshot[:status]
            refute_includes snapshot.keys, :tx_outputs_async
          end
        end
      end

      test "last activity uses current processing heartbeat first" do
        now = Time.current

        create_block(
          height: 956_250,
          status: "processed",
          processed_at: now - 5.minutes,
          updated_at: now - 4.minutes
        )

        create_block(
          height: 956_251,
          status: "processing",
          processing_started_at: now - 2.minutes,
          last_heartbeat_at: now - 3.seconds,
          updated_at: now - 1.minute
        )

        snapshot =
          realtime_snapshot(
            tip: 956_251
          )

        assert_in_delta(
          3,
          snapshot.dig(:activity, :last_activity_seconds_ago),
          2
        )
      end

      test "last activity falls back to processed_at" do
        now = Time.current

        create_block(
          height: 956_250,
          status: "processed",
          processed_at: now - 42.seconds,
          updated_at: now - 5.seconds
        )

        snapshot =
          realtime_snapshot(
            tip: 956_250
          )

        assert_in_delta(
          42,
          snapshot.dig(:activity, :last_activity_seconds_ago),
          2
        )
      end

      test "last activity falls back to updated_at" do
        now = Time.current

        create_block(
          height: 956_250,
          status: "processed",
          processed_at: nil,
          updated_at: now - 2.minutes
        )

        snapshot =
          realtime_snapshot(
            tip: 956_250
          )

        assert_in_delta(
          120,
          snapshot.dig(:activity, :last_activity_seconds_ago),
          2
        )
      end

      test "configured scheduler without heartbeat is not alive" do
        create_block(
          height: 956_250,
          status: "processed",
          processed_at: Time.current
        )

        snapshot =
          realtime_snapshot(
            tip: 956_250,
            redis: FakeRedis.new
          )

        assert_equal true,
                     snapshot.dig(:strict, :scheduler_configured)
        assert_equal false,
                     snapshot.dig(:strict, :scheduler_alive)
        assert_nil snapshot.dig(:strict, :last_scheduler_tick_at)
      end

      test "lag without active or queued strict work becomes stalled after sixty seconds" do
        now = Time.current

        create_block(
          height: 956_250,
          status: "processed",
          processed_at: now - 2.minutes
        )

        redis =
          FakeRedis.new(
            Layer1::Realtime::HealthSnapshot::LAYER1_STALLED_SINCE_KEY =>
              (now - 61.seconds).iso8601(6),
            System::DevelopmentBackfillPhase::STATE_KEY =>
              {
                phase: "layer1_catchup"
              }.to_json
          )

        snapshot =
          realtime_snapshot(
            tip: 956_260,
            redis: redis
          )

        assert_equal true,
                     snapshot.dig(:strict, :catch_up_active)
        assert_equal false,
                     snapshot.dig(:strict, :layer1_work_active)
        assert_equal false,
                     snapshot.dig(:strict, :layer1_work_queued)
        assert_equal true,
                     snapshot.dig(:strict, :stalled)
        assert_equal "layer1_stalled",
                     snapshot.dig(:strict, :anomaly)
        assert_operator snapshot.dig(:strict, :stalled_seconds),
                        :>=,
                        61
      end

      private

      def realtime_snapshot(tip:, redis: FakeRedis.new)
        service = Layer1::Realtime::HealthSnapshot.new

        service.define_singleton_method(:bitcoin_core_tip) do
          [tip, nil]
        end

        service.define_singleton_method(:strict_worker_process) do
          { present: true, busy: 0, process_count: 1 }
        end

        service.define_singleton_method(:strict_scheduler_snapshot) do
          { registered: true, enabled: true }
        end

        service.define_singleton_method(:queue_process) do |_queue_name|
          { present: true, busy: 0, process_count: 1 }
        end

        service.define_singleton_method(:queue_size) do |_queue_name|
          0
        end

        service.define_singleton_method(:scheduled_queue_size) do |_queue_name|
          0
        end

        service.define_singleton_method(:retry_queue_size) do |_queue_name|
          0
        end

        service.define_singleton_method(:layer1_workers) do
          []
        end

        with_stubbed(Redis, :new, redis) do
          service.call
        end
      end

      def create_block(height:, status:, **attributes)
        BlockBufferModel.create!(
          {
            height: height,
            block_hash: "#{height}-#{SecureRandom.hex(8)}",
            status: status,
            tx_count: 1,
            block_time: Time.current - 10.minutes
          }.merge(attributes)
        )
      end

      def with_stubbed(object, method_name, value = nil)
        original = object.method(method_name)
        replacement =
          if value.respond_to?(:call)
            value
          else
            ->(*_args, **_kwargs) { value }
          end

        object.define_singleton_method(method_name, &replacement)

        yield
      ensure
        object.define_singleton_method(method_name) do |*args, **kwargs, &block|
          original.call(*args, **kwargs, &block)
        end
      end
    end
  end
end
