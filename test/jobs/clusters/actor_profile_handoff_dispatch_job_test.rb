# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class ActorProfileHandoffDispatchJobTest < ActiveSupport::TestCase
    test "uses the dedicated ActorProfile strict queue" do
      assert_equal "actor_profile_strict", ActorProfileHandoffDispatchJob.new.queue_name
    end

    test "checks the Gate before one bounded dispatch and schedules one successor" do
      events = []
      scheduled = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |**arguments| scheduled << arguments }

      System::PipelineController.stub(:decision, ->(name) { events << [:gate, name]; { allowed: true } }) do
        ActorProfileHandoffDispatcher.stub(:call, ->(limit:) { events << [:dispatch, limit]; { ok: true, claimed: 1 } }) do
          ActorProfileHandoffDispatcher.stub(:work_available?, true) do
            ActorProfileHandoffDispatchJob.stub(:set, ->(wait:) {
              assert_equal 5.seconds, wait
              relation
            }) do
              assert_equal 1, ActorProfileHandoffDispatchJob.perform_now(limit: 4)[:claimed]
            end
          end
        end
      end

      assert_equal [[:gate, :actor_profile], [:dispatch, 4]], events
      assert_equal [{ limit: 4 }], scheduled
    end

    test "does not claim when Gate refuses and propagates Gate failures" do
      System::PipelineController.stub(:decision, { allowed: false }) do
        ActorProfileHandoffDispatcher.stub(:call, ->(**) { flunk "must not claim" }) do
          result = ActorProfileHandoffDispatchJob.perform_now
          assert_equal "pipeline_controller_refused", result[:reason]
        end
      end

      error = RuntimeError.new("gate unavailable")
      System::PipelineController.stub(:decision, ->(*) { raise error }) do
        ActorProfileHandoffDispatcher.stub(:call, ->(**) { flunk "must not claim" }) do
          assert_same error, assert_raises(RuntimeError) { ActorProfileHandoffDispatchJob.perform_now }
        end
      end

      System::PipelineController.stub(:decision, { unexpected: true }) do
        ActorProfileHandoffDispatcher.stub(:call, ->(**) { flunk "must not claim" }) do
          assert_raises(RuntimeError) { ActorProfileHandoffDispatchJob.perform_now }
        end
      end
    end

    test "bounds the limit and does not schedule when durable work is exhausted" do
      seen = []
      System::PipelineController.stub(:decision, { allowed: true }) do
        ActorProfileHandoffDispatcher.stub(:call, ->(limit:) { seen << limit; { ok: true, claimed: 0 } }) do
          ActorProfileHandoffDispatcher.stub(:work_available?, false) do
            ActorProfileHandoffDispatchJob.stub(:set, ->(*) { flunk "must not schedule" }) do
              ActorProfileHandoffDispatchJob.perform_now(limit: 10_000)
            end
          end
        end
      end
      assert_equal [ActorProfileHandoffDispatchJob::MAX_LIMIT], seen
    end

    test "propagates dispatcher errors without a second claim" do
      error = RuntimeError.new("dispatcher failed")
      calls = 0
      System::PipelineController.stub(:decision, { allowed: true }) do
        ActorProfileHandoffDispatcher.stub(:call, ->(**) { calls += 1; raise error }) do
          raised = assert_raises(RuntimeError) { ActorProfileHandoffDispatchJob.perform_now }
          assert_same error, raised
        end
      end
      assert_equal 1, calls
    end
  end
end
