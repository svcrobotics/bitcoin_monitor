# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerWatchdogClusterTest < ActiveSupport::TestCase
    FakeRedis = Struct.new(:unused)

    setup do
      @watchdog = SchedulerWatchdog.new(redis: FakeRedis.new)
    end

    test "builds the Cluster payload from the canonical default without legacy arguments" do
      with_cluster_limit(nil) do
        spec = cluster_spec

        assert_equal [{ limit: Clusters::StrictTipSyncJob::DEFAULT_LIMIT }], spec.args
        assert_equal [[:key, :limit], [:key, :start_height]],
          Clusters::StrictTipSyncJob.instance_method(:perform).parameters
        assert JSON.generate(spec.args)
        refute_includes spec.args.first.keys, :reschedule
        refute_includes spec.args.first.keys, :start_height
      end
    end

    test "passes a valid configured limit exactly and caps it at the canonical maximum" do
      with_cluster_limit("7") { assert_equal 7, cluster_spec.args.first[:limit] }
      with_cluster_limit("101") do
        assert_equal Clusters::StrictTipSyncer::MAX_LIMIT, cluster_spec.args.first[:limit]
      end
    end

    test "fails closed for zero negative blank and nonnumeric configuration" do
      ["0", "-1", "", "two"].each do |value|
        with_cluster_limit(value) do
          assert_raises(ArgumentError) { cluster_spec }
        end
      end
    end

    test "enqueues exactly one bounded Cluster job when PipelineController allows it" do
      enqueued = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |**arguments| enqueued << arguments }

      with_cluster_limit("3") do
        with_empty_cluster_state do
          System::PipelineController.stub(:decision, { allowed: true }) do
            Clusters::StrictTipSyncJob.stub(:set, ->(wait:) {
              assert_equal 10.seconds, wait
              relation
            }) do
              result = @watchdog.send(:check_job, cluster_spec)
              assert_equal true, result[:repaired]
            end
          end
        end
      end

      assert_equal [{ limit: 3 }], enqueued
    end

    test "the produced keywords are accepted by the bounded job signature" do
      arguments = with_cluster_limit("4") { cluster_spec.args.fetch(0) }
      job = Clusters::StrictTipSyncJob.new

      job.stub(:acquire_operational_lock, false) do
        result = job.perform(**arguments)
        assert_equal "operational_lock_held", result[:reason]
      end
    end

    test "does not enqueue when PipelineController refuses or fails" do
      [{ allowed: false }, ->(*) { raise "guard unavailable" }].each do |decision|
        with_empty_cluster_state do
          System::PipelineController.stub(:decision, decision) do
            Clusters::StrictTipSyncJob.stub(:set, ->(**) { flunk "must not enqueue" }) do
              result = @watchdog.send(:check_job, cluster_spec)
              assert_equal false, result[:repaired]
              assert_equal "pipeline_controller_refused", result[:reason]
            end
          end
        end
      end
    end

    test "constructing the Cluster specification performs no SQL and leaves other producers unchanged" do
      sql = capture_sql do
        @specs = with_cluster_limit(nil) { @watchdog.send(:job_specs) }
      end

      assert_empty sql
      layer1 = @specs.find { |spec| spec.name == "layer1" }
      actor_profile = @specs.find { |spec| spec.name == "actor_profile" }
      assert_equal [], layer1.args
      assert_equal true, actor_profile.args.first[:reschedule]
      assert_equal "Layer1::StrictTipSyncJob", layer1.klass
      assert_equal "ActorProfiles::StrictBatchJob", actor_profile.klass
    end

    private

    def cluster_spec
      @watchdog.send(:job_specs).find { |spec| spec.name == "cluster" }
    end

    def with_cluster_limit(value)
      existed = ENV.key?("CLUSTER_STRICT_SYNC_LIMIT")
      previous = ENV["CLUSTER_STRICT_SYNC_LIMIT"]
      value.nil? ? ENV.delete("CLUSTER_STRICT_SYNC_LIMIT") : ENV["CLUSTER_STRICT_SYNC_LIMIT"] = value
      yield
    ensure
      existed ? ENV["CLUSTER_STRICT_SYNC_LIMIT"] = previous : ENV.delete("CLUSTER_STRICT_SYNC_LIMIT")
    end

    def with_empty_cluster_state
      @watchdog.stub(:process_present_for_queue?, true) do
        @watchdog.stub(:matching_scheduled_jobs, []) do
          @watchdog.stub(:matching_queued_jobs, []) do
            @watchdog.stub(:active_count, 0) { yield }
          end
        end
      end
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end
  end
end
