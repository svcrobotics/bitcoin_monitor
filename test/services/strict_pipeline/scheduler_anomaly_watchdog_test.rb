# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerAnomalyWatchdogTest < ActiveSupport::TestCase
    test "scheduler invokes anomaly watchdog without changing job scheduling" do
      scheduler =
        StrictPipeline::Scheduler.new

      scheduler.define_singleton_method(:active_count) { |_queue| 0 }
      scheduler.define_singleton_method(:queued_count) { |_queue| 0 }
      scheduler.define_singleton_method(:scheduled_count) { |_queue| 0 }
      scheduler.define_singleton_method(:strict_lock_present?) { |_spec| false }
      scheduler.define_singleton_method(:enqueue) { |_spec| }
      scheduler.define_singleton_method(:ensure_actor_labels_worker_capability) { false }
      scheduler.define_singleton_method(:publish_runtime_status) { true }

      with_stubbed(System::PipelineController, :snapshot, stable_snapshot) do
        with_stubbed(System::PipelineController, :decision, ->(name, current_snapshot: nil) {
          {
            module: name,
            allowed: false,
            state: :idle,
            reason: nil,
            work_available: false,
            snapshot: current_snapshot
          }
        }) do
          with_stubbed(System::PipelineController, :work_available?, false) do
            with_stubbed(System::AnomalyWatchdog, :call, { ok: true, notified: false }) do
              result =
                scheduler.call

              assert_equal({ ok: true, notified: false }, result[:anomaly_watchdog])
            end
          end
        end
      end
    end

    private

    def stable_snapshot
      {
        bitcoin_core: {
          available: true
        },
        layer1: {},
        cluster: {},
        actor_profile: {}
      }
    end

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      object.define_singleton_method(method_name) do |*args, **kwargs|
        value.respond_to?(:call) ? value.call(*args, **kwargs) : value
      end

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
