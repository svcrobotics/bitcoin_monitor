# frozen_string_literal: true

require "test_helper"

module Layer1
  class TxOutputProjectionKickJobTest < ActiveSupport::TestCase
    test "requests a scheduler wakeup without enqueueing projection directly" do
      requested = nil
      direct_enqueued = false

      with_stubbed(
        StrictPipeline::SchedulerWakeup,
        :request!,
        lambda do |**kwargs|
          requested = kwargs
          { enqueued: true }
        end
      ) do
        with_stubbed(
          TxOutputProjectionJob,
          :perform_async,
          -> { direct_enqueued = true }
        ) do
          result =
            TxOutputProjectionKickJob
              .new
              .perform

          assert_equal true, result[:ok]
          assert_equal "wakeup_enqueued", result[:status]
        end
      end

      assert_equal(
        "tx_output_projection_kick",
        requested[:reason]
      )
      assert_equal false, direct_enqueued
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
