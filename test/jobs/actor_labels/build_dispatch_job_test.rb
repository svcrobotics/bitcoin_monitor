# frozen_string_literal: true
require "test_helper"
require "minitest/mock"
module ActorLabels
  class BuildDispatchJobTest < ActiveSupport::TestCase
    test "uses strict queue, gate and one bounded dispatch" do
      assert_equal "actor_labels_strict", BuildDispatchJob.queue_name
      calls = []
      System::PipelineController.stub(:decision, { allowed: true }) do
        BuildDispatcher.stub(:call, ->(limit:) { calls << limit; { ok: true } }) do
          BuildDispatcher.stub(:work_available?, false) do
            assert_equal({ ok: true }, BuildDispatchJob.new.perform(limit: 3))
          end
        end
      end
      assert_equal [3], calls
    end
    test "refusal performs no claim" do
      System::PipelineController.stub(:decision, { allowed: false }) do
        BuildDispatcher.stub(:call, ->(**) { flunk }) do
          assert_equal "skipped", BuildDispatchJob.new.perform[:status]
        end
      end
    end
  end
end
