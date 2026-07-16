# frozen_string_literal: true
require "test_helper"
module StrictPipeline
  class SchedulerWatchdogActorLabelsTest < ActiveSupport::TestCase
    test "declares one bounded durable ActorLabel producer" do
      watchdog = SchedulerWatchdog.new(redis: Object.new)
      spec = watchdog.send(:job_specs).find { |item| item.name == "actor_labels" }
      assert_equal "actor_labels_strict", spec.queue
      assert_equal "ActorLabels::BuildDispatchJob", spec.klass
      assert_equal [{ limit: ActorLabels::BuildDispatchJob::DEFAULT_LIMIT }], spec.args
    end
  end
end
