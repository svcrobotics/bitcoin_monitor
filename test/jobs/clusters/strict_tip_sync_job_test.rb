# frozen_string_literal: true

require "test_helper"

module Clusters
  class StrictTipSyncJobTest < ActiveSupport::TestCase
    test "does not schedule another job after cooperative yield" do
      scheduler_wakeups = 0

      with_stubbed(
        System::PipelineController,
        :decision,
        { allowed: true }
      ) do
        with_stubbed(StrictPipeline::StrictIoLease, :renew, true) do
          with_stubbed(StrictPipeline::StrictIoLease, :release, true) do
            with_stubbed(StrictPipeline::SchedulerWakeup, :request!, ->(**_kwargs) { scheduler_wakeups += 1 }) do
              with_stubbed(
                Clusters::StrictTipSyncer,
                :call,
                {
                  ok: true,
                  status: "yielded_to_layer1",
                  from_height: 100,
                  to_height: 101
                }
              ) do
                job = Clusters::StrictTipSyncJob.new

                job.define_singleton_method(:acquire_lock) { |_token| true }
                job.define_singleton_method(:release_lock) { |_token| true }
                job.define_singleton_method(:clear_schedule_marker) { true }

                result =
                  job.perform(
                    {
                      "limit" => 2,
                      "reschedule" => true,
                      "strict_io_token" => "cluster-token"
                    }
                  )

                assert_equal "yielded_to_layer1", result[:status]
              end
            end
          end
        end
      end

      assert_equal 1, scheduler_wakeups
    end

    test "cluster slice is capped at two blocks and ninety seconds" do
      received = nil

      with_stubbed(System::PipelineController, :decision, { allowed: true }) do
        with_stubbed(StrictPipeline::StrictIoLease, :renew, true) do
          with_stubbed(StrictPipeline::StrictIoLease, :release, true) do
            with_stubbed(StrictPipeline::SchedulerWakeup, :request!, ->(**_kwargs) {}) do
              with_stubbed(
                Clusters::StrictTipSyncer,
                :call,
                lambda do |**kwargs|
                  received = kwargs

                  {
                    ok: true,
                    status: "synced",
                    from_height: 100,
                    to_height: 101
                  }
                end
              ) do
                job = Clusters::StrictTipSyncJob.new

                job.define_singleton_method(:acquire_lock) { |_token| true }
                job.define_singleton_method(:release_lock) { |_token| true }
                job.define_singleton_method(:clear_schedule_marker) { true }

                job.perform(
                  {
                    "limit" => 10,
                    "reschedule" => true,
                    "strict_io_token" => "cluster-token"
                  }
                )
              end
            end
          end
        end
      end

      assert_equal 2, received[:limit]
      assert_equal 90, received[:max_runtime_seconds]
    end

    test "strict io denial wakes scheduler once without uncontrolled enqueue" do
      scheduler_wakeups = 0

      with_stubbed(StrictPipeline::StrictIoLease, :renew, false) do
        with_stubbed(StrictPipeline::SchedulerWakeup, :request!, ->(**_kwargs) { scheduler_wakeups += 1 }) do
          result =
            Clusters::StrictTipSyncJob.new.perform(
              {
                "limit" => 2,
                "strict_io_token" => "stale-token"
              }
            )

          assert_equal "skipped", result[:status]
          assert_equal "strict_io_lease_denied", result[:reason]
        end
      end

      assert_equal 1, scheduler_wakeups
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
