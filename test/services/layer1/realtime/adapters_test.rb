# frozen_string_literal: true

require "test_helper"

module Layer1
  module Realtime
    class AdaptersTest < ActiveSupport::TestCase
      class FakeRpc
        def initialize(times)
          @times = times
        end

        def getblockhash(height)
          "hash-#{height}"
        end

        def getblockheader(hash)
          height = hash.to_s.delete_prefix("hash-").to_i

          {
            "height" => height,
            "time" => @times.fetch(height),
            "previousblockhash" => "hash-#{height - 1}"
          }
        end
      end

      test "legacy health snapshot delegates to realtime health snapshot" do
        expected = { status: "healthy", processed_height: 956_250, lag: 0 }

        with_stubbed(
          Layer1::Realtime::HealthSnapshot,
          :call,
          expected
        ) do
          assert_equal expected, Layer1::HealthSnapshot.call
        end
      end

      test "legacy cached health snapshot delegates to realtime cached health snapshot" do
        expected = { status: "healthy" }

        with_stubbed(
          Layer1::Realtime::CachedHealthSnapshot,
          :read,
          expected
        ) do
          assert_equal expected, Layer1::CachedHealthSnapshot.read
        end

        with_stubbed(
          Layer1::Realtime::CachedHealthSnapshot,
          :refresh!,
          expected
        ) do
          assert_equal expected, Layer1::CachedHealthSnapshot.refresh!
        end
      end

      test "legacy operational snapshot delegates to realtime operational snapshot" do
        expected = { status: "healthy", source: "layer1_operational_snapshot" }

        with_stubbed(
          Layer1::Realtime::OperationalSnapshot,
          :call,
          expected
        ) do
          assert_equal expected, Layer1::OperationalSnapshot.call
        end
      end

      test "legacy recent cadence snapshot matches realtime recent cadence snapshot" do
        times = {
          100 => 1_000,
          101 => 1_600,
          102 => 2_200,
          103 => 2_800,
          104 => 3_400,
          105 => 4_000
        }

        kwargs = {
          tip_height: 105,
          processed_height: 104,
          processing_height: 105,
          rpc: FakeRpc.new(times),
          cache: nil,
          now: Time.at(4_030),
          certification_average_seconds: 90
        }

        realtime =
          Layer1::Realtime::RecentBlockCadenceSnapshot.call(**kwargs)

        legacy =
          Layer1::RecentBlockCadenceSnapshot.call(
            **kwargs.merge(rpc: FakeRpc.new(times))
          )

        assert_equal realtime, legacy
      end

      test "realtime snapshot files do not call audit or heavy classes" do
        realtime_files = %w[
          app/services/layer1/realtime/health_snapshot.rb
          app/services/layer1/realtime/cached_health_snapshot.rb
          app/services/layer1/realtime/operational_snapshot.rb
          app/services/layer1/realtime/recent_block_cadence_snapshot.rb
        ]

        source =
          realtime_files.map do |path|
            Rails.root.join(path).read
          end.join("\n")

        refute_match(/\bLayer1::Audit\b/, source)
        refute_match(/\bLayer1AuditRun\b/, source)
        refute_match(/\bAuditBlock\b/, source)
        refute_match(/\bHeavy\b/, source)
        refute_match(/\bLayer1::TxOutputsSpentSync\b/, source)
        refute_match(/\bLayer1TxOutputSync\b/, source)
        refute_match(/\bReconcileSpentOutputs\b/, source)
        refute_match(/\btx_outputs_async\b/, source)
      end

      test "zeitwerk loads realtime constants and legacy adapters" do
        assert_equal(
          Layer1::Realtime::CachedHealthSnapshot,
          "Layer1::Realtime::CachedHealthSnapshot".constantize
        )
        assert_equal(
          Layer1::Realtime::OperationalSnapshot,
          "Layer1::Realtime::OperationalSnapshot".constantize
        )
        assert_equal(
          Layer1::Realtime::RecentBlockCadenceSnapshot,
          "Layer1::Realtime::RecentBlockCadenceSnapshot".constantize
        )
        assert_equal(
          Layer1::CachedHealthSnapshot,
          "Layer1::CachedHealthSnapshot".constantize
        )
        assert_equal(
          Layer1::OperationalSnapshot,
          "Layer1::OperationalSnapshot".constantize
        )
        assert_equal(
          Layer1::RecentBlockCadenceSnapshot,
          "Layer1::RecentBlockCadenceSnapshot".constantize
        )
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
