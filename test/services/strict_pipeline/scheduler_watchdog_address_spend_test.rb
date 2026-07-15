# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerWatchdogAddressSpendTest < ActiveSupport::TestCase
    FakeRedis = Struct.new(:unused)
    setup { @watchdog = SchedulerWatchdog.new(redis: FakeRedis.new) }

    test "places AddressSpend before handoffs on the shared single-concurrency queue" do
      specs = @watchdog.send(:job_specs)
      spend = specs.find { |spec| spec.name == "address_spend_projection" }
      profile = specs.find { |spec| spec.name == "actor_profile" }
      assert_operator specs.index(spend), :<, specs.index(profile)
      assert_equal "actor_profile_strict", spend.queue
      assert_equal "AddressSpendStats::ProjectionJob", spend.klass
      assert_equal "actor_profile_strict", profile.queue
      assert JSON.generate(spend.args)
    end

    test "enqueues one projection and suppresses handoff dispatch while projection work exists" do
      enqueued = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |arguments| enqueued << arguments }
      with_empty_state do
        AddressSpendStats::NextRecord.stub(:call, Object.new) do
          System::PipelineController.stub(:decision, { allowed: true }) do
            AddressSpendStats::ProjectionJob.stub(:set, ->(wait:) { assert_equal 10.seconds, wait; relation }) do
              assert_equal true, @watchdog.send(:check_job, spend_spec)[:repaired]
            end
            result = @watchdog.send(:check_job, profile_spec)
            assert_equal "address_spend_projection_pending", result[:reason]
          end
        end
      end
      assert_equal 1, enqueued.size
    end

    test "does not enqueue when projection Gate refuses" do
      with_empty_state do
        AddressSpendStats::NextRecord.stub(:call, Object.new) do
          System::PipelineController.stub(:decision, { allowed: false }) do
            AddressSpendStats::ProjectionJob.stub(:set, ->(**) { flunk "must not enqueue" }) do
              assert_equal "pipeline_controller_refused", @watchdog.send(:check_job, spend_spec)[:reason]
            end
          end
        end
      end
    end

    private

    def spend_spec = @watchdog.send(:job_specs).find { |spec| spec.name == "address_spend_projection" }
    def profile_spec = @watchdog.send(:job_specs).find { |spec| spec.name == "actor_profile" }

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
