# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerWatchdogClusterTransactionProjectionTest < ActiveSupport::TestCase
    FakeRedis = Struct.new(:unused)

    setup do
      @watchdog = SchedulerWatchdog.new(redis: FakeRedis.new)
    end

    test "defines one bounded CTP producer on the existing Cluster queue" do
      specs = @watchdog.send(:job_specs)
      ctp_specs = specs.select { |spec| spec.name == "cluster_transaction_projection" }

      assert_equal 1, ctp_specs.size
      assert_equal "cluster_strict", ctp_spec.queue
      assert_equal "ClusterTransactionProjection::IncrementalDispatchJob", ctp_spec.klass
      assert_equal :active_job, ctp_spec.kind
      assert_equal [{ limit: 1 }], ctp_spec.args
      assert_equal false, ctp_spec.allow_scheduled_successor_while_active
      assert JSON.generate(ctp_spec.args)
    end

    test "checks Cluster priority then PipelineController then durable CTP work" do
      calls = []
      repairs = []

      with_empty_ctp_state do
        Clusters::StrictTipSyncer.stub(:work_available?, -> { calls << :cluster_work; false }) do
          System::PipelineController.stub(:decision, ->(role) {
            calls << :pipeline_cluster if role == :cluster
            { allowed: true }
          }) do
            ClusterTransactionProjection::IncrementalDispatcher.stub(
              :work_available?,
              -> { calls << :ctp; true }
            ) do
              @watchdog.stub(:repair, ->(spec) { repairs << spec.klass }) do
                result = @watchdog.send(:check_job, ctp_spec)

                assert_equal true, result[:repaired]
              end
            end
          end
        end
      end

      assert_equal [:cluster_work, :pipeline_cluster, :ctp], calls
      assert_equal ["ClusterTransactionProjection::IncrementalDispatchJob"], repairs
    end

    test "does not enqueue while strict Cluster work has priority" do
      with_empty_ctp_state do
        Clusters::StrictTipSyncer.stub(:work_available?, true) do
          System::PipelineController.stub(:decision, ->(*) { flunk "must not consult the gate" }) do
            ClusterTransactionProjection::IncrementalDispatcher.stub(
              :work_available?,
              -> { flunk "must not probe CTP work" }
            ) do
              @watchdog.stub(:repair, ->(*) { flunk "must not enqueue" }) do
                result = @watchdog.send(:check_job, ctp_spec)

                assert_equal false, result[:repaired]
                assert_equal "cluster_strict_work_pending", result[:reason]
              end
            end
          end
        end
      end
    end

    test "fails closed when PipelineController refuses or fails" do
      [{ allowed: false }, ->(*) { raise "gate unavailable" }].each do |decision|
        with_empty_ctp_state do
          Clusters::StrictTipSyncer.stub(:work_available?, false) do
            System::PipelineController.stub(:decision, decision) do
              ClusterTransactionProjection::IncrementalDispatcher.stub(
                :work_available?,
                -> { flunk "must not probe CTP work" }
              ) do
                @watchdog.stub(:repair, ->(*) { flunk "must not enqueue" }) do
                  result = @watchdog.send(:check_job, ctp_spec)

                  assert_equal false, result[:repaired]
                  assert_equal "pipeline_controller_refused", result[:reason]
                end
              end
            end
          end
        end
      end
    end

    test "does not enqueue without durable CTP work" do
      with_empty_ctp_state do
        with_allowed_idle_cluster do
          ClusterTransactionProjection::IncrementalDispatcher.stub(:work_available?, false) do
            @watchdog.stub(:repair, ->(*) { flunk "must not enqueue" }) do
              result = @watchdog.send(:check_job, ctp_spec)

              assert_equal false, result[:repaired]
              assert_equal "durable_backlog_empty", result[:reason]
            end
          end
        end
      end
    end

    test "recognizes the exact CTP class in queued scheduled and active payloads" do
      expected = "ClusterTransactionProjection::IncrementalDispatchJob"
      other = "Clusters::StrictTipSyncJob"

      assert @watchdog.send(:payload_matches?, { "class" => expected }, ctp_spec)
      assert @watchdog.send(:payload_matches?, { "wrapped" => expected }, ctp_spec)
      assert @watchdog.send(
        :payload_matches?,
        { "args" => [{ "job_class" => expected }] },
        ctp_spec
      )
      refute @watchdog.send(:payload_matches?, { "class" => other }, ctp_spec)

      [
        { scheduled: [fake_job], queued: [], active: 0 },
        { scheduled: [], queued: [fake_job], active: 0 },
        { scheduled: [], queued: [], active: 1 }
      ].each do |state|
        with_ctp_state(**state) do
          @watchdog.stub(:repair, ->(*) { flunk "must not enqueue a duplicate" }) do
            result = @watchdog.send(:check_job, ctp_spec)

            assert_equal true, result[:present]
            assert_equal false, result[:repaired]
          end
        end
      end
    end

    test "an inspection failure never enqueues" do
      @watchdog.stub(:process_present_for_queue?, true) do
        @watchdog.stub(:matching_scheduled_jobs, ->(*) { raise "Sidekiq unavailable" }) do
          @watchdog.stub(:repair, ->(*) { flunk "must not enqueue" }) do
            result = @watchdog.send(:check_job, ctp_spec)

            assert_equal false, result[:repaired]
            assert_equal "RuntimeError", result[:error_class]
          end
        end
      end
    end

    test "a lost job is rediscovered on the next watchdog cycle" do
      repairs = []

      2.times do
        with_empty_ctp_state do
          with_allowed_idle_cluster do
            ClusterTransactionProjection::IncrementalDispatcher.stub(:work_available?, true) do
              @watchdog.stub(:repair, ->(spec) { repairs << spec.klass }) do
                assert_equal true, @watchdog.send(:check_job, ctp_spec)[:repaired]
              end
            end
          end
        end
      end

      assert_equal [
        "ClusterTransactionProjection::IncrementalDispatchJob",
        "ClusterTransactionProjection::IncrementalDispatchJob"
      ], repairs
    end

    private

    def ctp_spec
      @watchdog.send(:job_specs).find do |spec|
        spec.name == "cluster_transaction_projection"
      end
    end

    def with_allowed_idle_cluster
      Clusters::StrictTipSyncer.stub(:work_available?, false) do
        System::PipelineController.stub(:decision, { allowed: true }) { yield }
      end
    end

    def with_empty_ctp_state(&block)
      with_ctp_state(scheduled: [], queued: [], active: 0, &block)
    end

    def with_ctp_state(scheduled:, queued:, active:)
      @watchdog.stub(:process_present_for_queue?, true) do
        @watchdog.stub(:matching_scheduled_jobs, scheduled) do
          @watchdog.stub(:matching_queued_jobs, queued) do
            @watchdog.stub(:active_count, active) { yield }
          end
        end
      end
    end

    def fake_job
      Struct.new(:at).new(Time.current.to_f)
    end
  end
end
