# frozen_string_literal: true

require "test_helper"

module Layer1
  class OverviewSnapshotTest < ActiveSupport::TestCase
    test "historical projection error does not degrade realtime status" do
      realtime = {
        status: "healthy",
        processed_height: 956_250
      }

      with_stubbed(Layer1::Realtime::HealthSnapshot, :call, realtime) do
        with_stubbed(
          Layer1::Audit::OperationalSnapshot,
          :call,
          { status: "healthy" }
        ) do
          with_stubbed(
            Layer1::TxOutputsSpentSync::OperationalSnapshot,
            :call,
            ->(*) { raise "projection failed" }
          ) do
            overview = Layer1::OverviewSnapshot.call

            assert_equal "healthy", overview.dig(:realtime, :status)
            assert_equal(
              "unavailable",
              overview.dig(:historical_projection, :status)
            )
            assert_match(
              /projection failed/,
              overview.dig(:historical_projection, :error)
            )
          end
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
