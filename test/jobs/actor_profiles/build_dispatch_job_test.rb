# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class BuildDispatchJobTest < ActiveSupport::TestCase
    test "uses the strict queue and gates one bounded dispatch" do
      assert_equal "actor_profile_strict", BuildDispatchJob.new.queue_name
      events = []
      System::PipelineController.stub(:decision, ->(name) { events << [:gate, name]; { allowed: true } }) do
        BuildDispatcher.stub(:call, ->(limit:) { events << [:dispatch, limit]; { ok: true } }) do
          BuildDispatcher.stub(:work_available?, false) do
            BuildDispatchJob.perform_now(limit: 4)
          end
        end
      end
      assert_equal [[:gate, :actor_profile], [:dispatch, 4]], events
    end

    test "refusal makes no claim and durable work schedules one successor" do
      System::PipelineController.stub(:decision, { allowed: false }) do
        BuildDispatcher.stub(:call, ->(**) { flunk "must not dispatch" }) do
          assert_equal "pipeline_controller_refused", BuildDispatchJob.perform_now[:reason]
        end
      end

      scheduled = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |**args| scheduled << args }
      System::PipelineController.stub(:decision, { allowed: true }) do
        BuildDispatcher.stub(:call, { ok: true }) do
          BuildDispatcher.stub(:work_available?, true) do
            BuildDispatchJob.stub(:set, ->(wait:) { assert_equal 5.seconds, wait; relation }) do
              BuildDispatchJob.perform_now(limit: 3)
            end
          end
        end
      end
      assert_equal [{ limit: 3 }], scheduled
    end

    test "dispatcher errors propagate without a real queue" do
      error = RuntimeError.new("dispatch failed")
      System::PipelineController.stub(:decision, { allowed: true }) do
        BuildDispatcher.stub(:call, ->(**) { raise error }) do
          assert_same error, assert_raises(RuntimeError) { BuildDispatchJob.perform_now }
        end
      end
    end
  end
end
