# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ClusterTransactionProjection
  class IncrementalDispatchJobTest < ActiveSupport::TestCase
    test "uses the cluster strict queue and dispatches one bounded candidate" do
      calls = []
      result = { ok: true, selected: 1 }

      with_pipeline_decision(allowed: true) do
        with_dispatcher_call(->(**arguments) { calls << arguments; result }) do
          assert_same result, IncrementalDispatchJob.new.perform(limit: 1)
        end
      end

      assert_equal "cluster_strict", IncrementalDispatchJob.new.queue_name
      assert_equal [{ limit: 1 }], calls
    end

    test "refuses before dispatch when PipelineController denies Cluster" do
      with_pipeline_decision(allowed: false, reason: "layer1_priority") do
        with_dispatcher_call(->(**) { flunk "dispatcher must not run" }) do
          result = IncrementalDispatchJob.new.perform(limit: 1)
          assert_equal "skipped", result[:status]
          assert_equal "pipeline_controller_refused", result[:reason]
        end
      end
    end

    test "fails closed on an invalid or unavailable PipelineController decision" do
      with_pipeline_decision(status: "unknown") do
        with_dispatcher_call(->(**) { flunk "dispatcher must not run" }) do
          assert_raises(RuntimeError) { IncrementalDispatchJob.new.perform(limit: 1) }
        end
      end

      System::PipelineController.stub(:decision, ->(*) { raise "controller unavailable" }) do
        with_dispatcher_call(->(**) { flunk "dispatcher must not run" }) do
          error = assert_raises(RuntimeError) { IncrementalDispatchJob.new.perform(limit: 1) }
          assert_equal "controller unavailable", error.message
        end
      end
    end

    test "rejects every unbounded or invalid limit" do
      with_pipeline_decision(allowed: true) do
        with_dispatcher_call(->(**) { flunk "dispatcher must not run" }) do
          [nil, 0, -1, 2, "invalid"].each do |limit|
            assert_raises(ArgumentError, "limit=#{limit.inspect}") do
              IncrementalDispatchJob.new.perform(limit: limit)
            end
          end
        end
      end
    end

    test "propagates the dispatcher BatchError unchanged for retry" do
      batch = IncrementalDispatcher::BatchResult.new(ok: false, failed: 1, candidates: [])
      failure = IncrementalDispatcher::BatchError.new(batch)

      with_pipeline_decision(allowed: true) do
        with_dispatcher_call(->(**) { raise failure }) do
          raised = assert_raises(IncrementalDispatcher::BatchError) do
            IncrementalDispatchJob.new.perform(limit: 1)
          end
          assert_same failure, raised
        end
      end
    end

    test "contains no scheduling or direct Redis dependency" do
      source = File.read(
        Rails.root.join(
          "app/jobs/cluster_transaction_projection/incremental_dispatch_job.rb"
        )
      )

      refute_match(/perform_later|perform_async|\.set\(|Redis|Sidekiq/, source)
      refute_match(/cluster_id|generation_id|block_hash|composition_version/, source)
    end

    private

    def with_pipeline_decision(decision)
      System::PipelineController.stub(:decision, ->(role) {
        assert_equal :cluster, role
        decision
      }) { yield }
    end

    def with_dispatcher_call(replacement)
      original = IncrementalDispatcher.method(:call)
      IncrementalDispatcher.define_singleton_method(:call) do |*args, **kwargs, &block|
        replacement.call(*args, **kwargs, &block)
      end
      yield
    ensure
      IncrementalDispatcher.define_singleton_method(:call) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
