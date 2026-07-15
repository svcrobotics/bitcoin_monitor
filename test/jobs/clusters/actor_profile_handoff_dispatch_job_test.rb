# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class ActorProfileHandoffDispatchJobTest < ActiveSupport::TestCase
    test "uses the consumed Cluster strict queue" do
      assert_equal "cluster_strict", ActorProfileHandoffDispatchJob.new.queue_name
    end

    test "invokes one bounded dispatch and schedules once only when PostgreSQL work remains" do
      calls = []
      scheduled = []
      dispatcher = ->(limit:) { calls << limit; { ok: true, claimed: 1 } }
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |**arguments| scheduled << arguments }

      ActorProfileHandoffDispatcher.stub(:call, dispatcher) do
        ActorProfileHandoffDispatcher.stub(:work_available?, true) do
          ActorProfileHandoffDispatchJob.stub(:set, ->(wait:) {
            assert_equal 1.second, wait
            relation
          }) do
            result = ActorProfileHandoffDispatchJob.perform_now(limit: 4)
            assert_equal 1, result[:claimed]
          end
        end
      end

      assert_equal [4], calls
      assert_equal [{ limit: 4 }], scheduled
    end

    test "does not schedule when no durable work remains" do
      ActorProfileHandoffDispatcher.stub(:call, { ok: true, claimed: 0 }) do
        ActorProfileHandoffDispatcher.stub(:work_available?, false) do
          ActorProfileHandoffDispatchJob.stub(:set, ->(*) { flunk "must not schedule" }) do
            assert_equal 0, ActorProfileHandoffDispatchJob.perform_now[:claimed]
          end
        end
      end
    end

    test "propagates dispatcher errors without touching a real queue" do
      error = RuntimeError.new("dispatcher failed")
      ActorProfileHandoffDispatcher.stub(:call, ->(**) { raise error }) do
        raised = assert_raises(RuntimeError) { ActorProfileHandoffDispatchJob.perform_now }
        assert_same error, raised
      end
    end
  end
end
