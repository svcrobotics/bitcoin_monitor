# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerWatchdogActorBehaviorTest < ActiveSupport::TestCase
    FakeRedis = Struct.new(:unused)

    setup { @watchdog = SchedulerWatchdog.new(redis: FakeRedis.new) }

    test "uses the durable ActorBehavior job and repairs exactly once" do
      spec = actor_behavior_spec
      assert_equal "actor_behavior_strict", spec.queue
      assert_equal "ActorBehaviors::BuildDispatchJob", spec.klass
      assert_equal [{ limit: ActorBehaviors::BuildDispatchJob::DEFAULT_LIMIT }], spec.args
      enqueued = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |arguments| enqueued << arguments }
      with_empty_state do
        ActorBehaviors::BuildDispatcher.stub(:work_available?, true) do
          System::PipelineController.stub(:decision, { allowed: true }) do
            ActorBehaviors::BuildDispatchJob.stub(:set, ->(wait:) {
              assert_equal 20.seconds, wait
              relation
            }) do
              assert @watchdog.send(:check_job, spec)[:repaired]
            end
          end
        end
      end
      assert_equal [{ limit: ActorBehaviors::BuildDispatchJob::DEFAULT_LIMIT }], enqueued
    end

    test "empty backlog and gate refusal do not enqueue" do
      [[false, { allowed: true }, "durable_backlog_empty"],
       [true, { allowed: false }, "pipeline_controller_refused"]].each do |work, decision, reason|
        with_empty_state do
          ActorBehaviors::BuildDispatcher.stub(:work_available?, work) do
            System::PipelineController.stub(:decision, decision) do
              ActorBehaviors::BuildDispatchJob.stub(:set, ->(**) { flunk "must not enqueue" }) do
                result = @watchdog.send(:check_job, actor_behavior_spec)
                assert_equal reason, result[:reason]
              end
            end
          end
        end
      end
    end

    private

    def actor_behavior_spec
      @watchdog.send(:job_specs).find { |spec| spec.name == "actor_behavior" }
    end

    def with_empty_state
      @watchdog.stub(:process_present_for_queue?, true) do
        @watchdog.stub(:matching_scheduled_jobs, []) do
          @watchdog.stub(:matching_queued_jobs, []) do
            @watchdog.stub(:active_count, 0) { yield }
          end
        end
      end
    end
  end
end
