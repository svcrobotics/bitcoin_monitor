# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerWatchdogActorProfileTest < ActiveSupport::TestCase
    FakeRedis = Struct.new(:unused)

    setup { @watchdog = SchedulerWatchdog.new(redis: FakeRedis.new) }

    test "uses the durable outbox job and dedicated queue" do
      spec = actor_profile_spec
      assert_equal "actor_profile_strict", spec.queue
      assert_equal "Clusters::ActorProfileHandoffDispatchJob", spec.klass
      assert_equal [{ limit: Clusters::ActorProfileHandoffDispatchJob::DEFAULT_LIMIT }], spec.args
      assert JSON.generate(spec.args)
    end

    test "rediscovers PostgreSQL work and enqueues one job while Cluster is idle" do
      enqueued = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |arguments| enqueued << arguments }
      with_empty_state do
        Clusters::ActorProfileHandoffDispatcher.stub(:work_available?, true) do
          System::PipelineController.stub(:decision, { allowed: true }) do
            Clusters::ActorProfileHandoffDispatchJob.stub(:set, ->(wait:) {
              assert_equal 15.seconds, wait
              relation
            }) do
              assert_equal true, @watchdog.send(:check_job, actor_profile_spec)[:repaired]
            end
          end
        end
      end
      assert_equal [{ limit: Clusters::ActorProfileHandoffDispatchJob::DEFAULT_LIMIT }], enqueued
    end

    test "does not enqueue without durable work or when Gate refuses" do
      [[false, { allowed: true }, "durable_backlog_empty"],
       [true, { allowed: false }, "pipeline_controller_refused"],
       [true, ->(*) { raise "gate failed" }, "pipeline_controller_refused"]].each do |work, decision, reason|
        with_empty_state do
          Clusters::ActorProfileHandoffDispatcher.stub(:work_available?, work) do
            System::PipelineController.stub(:decision, decision) do
              Clusters::ActorProfileHandoffDispatchJob.stub(:set, ->(**) { flunk "must not enqueue" }) do
                result = @watchdog.send(:check_job, actor_profile_spec)
                assert_equal false, result[:repaired]
                assert_equal reason, result[:reason]
              end
            end
          end
        end
      end
    end

    private

    def actor_profile_spec
      @watchdog.send(:job_specs).find { |spec| spec.name == "actor_profile" }
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
