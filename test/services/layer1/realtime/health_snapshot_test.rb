# frozen_string_literal: true

require "test_helper"

module Layer1
  module Realtime
    class HealthSnapshotTest < ActiveSupport::TestCase
      class FakeRedis
        def llen(_key)
          0
        end

        def exists?(_key)
          false
        end

        def ttl(_key)
          -2
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

      private

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
