# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerWakeupTest < ActiveJob::TestCase
    include ActiveJob::TestHelper

    setup do
      @original_base_queue_adapter =
        ActiveJob::Base.queue_adapter

      @original_scheduler_queue_adapter =
        StrictPipeline::SchedulerJob.queue_adapter

      @test_queue_adapter =
        ActiveJob::QueueAdapters::TestAdapter.new

      ActiveJob::Base.queue_adapter =
        @test_queue_adapter

      StrictPipeline::SchedulerJob.queue_adapter =
        @test_queue_adapter

      clear_runtime!
      clear_enqueued_jobs
      clear_performed_jobs
    end

    teardown do
      begin
        clear_runtime!
        clear_enqueued_jobs
        clear_performed_jobs
      ensure
        StrictPipeline::SchedulerJob.queue_adapter =
          @original_scheduler_queue_adapter

        ActiveJob::Base.queue_adapter =
          @original_base_queue_adapter
      end
    end

    test "one hundred wakeup requests enqueue at most one scheduler job" do
      results =
        100.times.map do
          StrictPipeline::SchedulerWakeup.request!(
            reason: "test_concurrent"
          )
        end

      assert_equal 1, enqueued_jobs.size
      assert_equal 1, results.count { |result| result[:enqueued] }
      assert_equal 99, results.count { |result| result[:duplicate] }
    end

    test "request with scheduler already queued adds nothing" do
      StrictPipeline::SchedulerJob.perform_later

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "already_queued"
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal 1, enqueued_jobs.size
    end

    test "request with scheduler already scheduled adds nothing" do
      StrictPipeline::SchedulerJob
        .set(wait: 60.seconds)
        .perform_later

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "already_scheduled"
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal 1, enqueued_jobs.size
    end

    test "immediate request advances existing thirty second wakeup" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "periodic",
        wait: 30.seconds
      )

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "layer1_block_completed_with_backlog"
        )

      assert_equal true, result[:enqueued]
      assert_equal 1, scheduler_jobs.size
      assert_nil scheduled_at(scheduler_jobs.first)
    end

    test "later request does not push back existing immediate wakeup" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "immediate"
      )

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "periodic",
          wait: 30.seconds
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal 1, scheduler_jobs.size
      assert_nil scheduled_at(scheduler_jobs.first)
    end

    test "ten second request advances existing thirty second wakeup" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "periodic",
        wait: 30.seconds
      )

      StrictPipeline::SchedulerWakeup.request!(
        reason: "layer1_backlog",
        wait: 10.seconds
      )

      assert_equal 1, scheduler_jobs.size
      assert_in_delta(
        10.seconds.from_now.to_f,
        scheduled_at(scheduler_jobs.first).to_f,
        2.0
      )
    end

    test "two second layer1 handoff advances existing thirty second periodic wakeup" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "periodic",
        wait: 30.seconds
      )

      StrictPipeline::SchedulerWakeup.request!(
        reason: "layer1_block_completed_with_backlog",
        wait: 2.seconds
      )

      assert_equal 1, scheduler_jobs.size
      assert_in_delta(
        2.seconds.from_now.to_f,
        scheduled_at(scheduler_jobs.first).to_f,
        2.0
      )
    end

    test "two second layer1 handoff does not push back existing immediate wakeup" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "immediate"
      )

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "layer1_block_completed_with_backlog",
          wait: 2.seconds
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal 1, scheduler_jobs.size
      assert_nil scheduled_at(scheduler_jobs.first)
    end

    test "thirty second request does not push back existing ten second wakeup" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "near",
        wait: 10.seconds
      )

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "periodic",
          wait: 30.seconds
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal 1, scheduler_jobs.size
      assert_in_delta(
        10.seconds.from_now.to_f,
        scheduled_at(scheduler_jobs.first).to_f,
        2.0
      )
    end

    test "many competing requests keep one job at the earliest due time" do
      waits =
        [
          30.seconds,
          20.seconds,
          10.seconds,
          0.seconds
        ]

      100.times do |index|
        StrictPipeline::SchedulerWakeup.request!(
          reason: "race_#{index}",
          wait: waits[index % waits.size]
        )
      end

      assert_equal 1, scheduler_jobs.size
      assert_nil scheduled_at(scheduler_jobs.first)
    end

    test "request with scheduler active adds nothing" do
      set_active_lock!("token")

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "already_active"
        )

      assert_equal false, result[:enqueued]
      assert_equal false, result[:duplicate]
      assert_equal true, result[:pending]
      assert_equal 0, enqueued_jobs.size
    end

    test "immediate request while scheduler is active is handed off later" do
      set_active_lock!("token")

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "active_immediate"
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:pending]
      assert_equal 0, scheduler_jobs.size

      redis_call(
        "DEL",
        StrictPipeline::SchedulerJob::ACTIVE_KEY
      )

      flush =
        StrictPipeline::SchedulerWakeup.flush_pending!

      assert_equal true, flush[:enqueued]
      assert_equal true, flush[:pending_handoff]
      assert_equal 1, scheduler_jobs.size
      assert_nil scheduled_at(scheduler_jobs.first)
    end

    test "request with scheduler active in work set adds nothing" do
      with_instance_stub(
        StrictPipeline::SchedulerWakeup,
        :scheduler_work_count,
        -> { 1 }
      ) do
        result =
          StrictPipeline::SchedulerWakeup.request!(
            reason: "workset_active"
          )

        assert_equal false, result[:enqueued]
        assert_equal true, result[:duplicate]
        assert_equal 0, enqueued_jobs.size
      end
    end

    test "valid marker prevents duplicate when scheduler job exists" do
      set_wakeup_marker!
      StrictPipeline::SchedulerJob.perform_later

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "marker_present"
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal 1, enqueued_jobs.size
    end

    test "stale marker without scheduler job is repaired" do
      set_wakeup_marker!(
        due_at:
          Time.current.to_f -
            StrictPipeline::SchedulerWakeup::
              SCHEDULED_TO_ACTIVE_GRACE_SECONDS -
            1
      )

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "stale_marker"
        )

      assert_equal true, result[:enqueued]
      assert_equal false, result[:duplicate]
      assert_equal 1, enqueued_jobs.size
      assert_equal true, wakeup_marker_present?
    end

    test "scheduled to active transition marker does not create second scheduler job" do
      set_wakeup_marker!(
        due_at: Time.current.to_f
      )

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "transition_window"
        )

      assert_equal false, result[:enqueued]
      assert_equal true, result[:duplicate]
      assert_equal "scheduler_transition_in_progress",
                   result[:duplicate_reason]
      assert_equal 0, scheduler_jobs.size
      assert_equal true, wakeup_marker_present?
    end

    test "redis error never enqueues blindly" do
      with_stubbed(
        Sidekiq,
        :redis,
        ->(&block) { raise RuntimeError, "redis down" }
      ) do
        result =
          StrictPipeline::SchedulerWakeup.request!(
            reason: "redis_down"
          )

        assert_equal false, result[:enqueued]
        assert_equal 0, enqueued_jobs.size
      end
    end

    test "enqueue failure removes created marker" do
      with_stubbed(
        StrictPipeline::SchedulerJob,
        :perform_later,
        -> { raise RuntimeError, "enqueue failed" }
      ) do
        result =
          StrictPipeline::SchedulerWakeup.request!(
            reason: "enqueue_failure"
          )

        assert_equal false, result[:enqueued]
        assert_equal false, wakeup_marker_present?
      end
    end

    test "deferred removal failure does not multiply scheduler jobs" do
      StrictPipeline::SchedulerWakeup.request!(
        reason: "periodic",
        wait: 30.seconds
      )

      with_instance_stub(
        StrictPipeline::SchedulerWakeup,
        :remove_deferred_scheduler_jobs,
        -> { false }
      ) do
        result =
          StrictPipeline::SchedulerWakeup.request!(
            reason: "nearer",
            wait: 10.seconds
          )

        assert_equal false, result[:enqueued]
        assert_equal "deferred_scheduler_job_removal_failed",
                     result[:error]
        assert_equal 1, scheduler_jobs.size
      end
    end

    test "critical scheduler queue size blocks enqueue" do
      with_instance_stub(
        StrictPipeline::SchedulerWakeup,
        :scheduler_queue_size,
        -> { StrictPipeline::SchedulerWakeup::CRITICAL_QUEUE_SIZE }
      ) do
        result =
          StrictPipeline::SchedulerWakeup.request!(
            reason: "critical_queue"
          )

        assert_equal false, result[:enqueued]
        assert_equal true, result[:blocked]
        assert_equal "scheduler_queue_critical",
                     result[:blocked_reason]
        assert_equal 0, enqueued_jobs.size
      end
    end

    test "projection kick jobs coalesce to one scheduler wakeup" do
      Layer1::TxOutputsSpentSyncKickJob.new.perform
      Layer1::TxOutputProjectionKickJob.new.perform

      assert_equal 1, enqueued_jobs.size
    end

    test "layer1 strict kick runs scheduler job directly" do
      calls = []

      with_instance_stub(
        StrictPipeline::SchedulerJob,
        :perform,
        lambda do
          calls << :perform
          {
            ok: true
          }
        end
      ) do
        result =
          Layer1::StrictTipSyncKickJob.new.perform

        assert_equal "scheduler_checked", result[:status]
      end

      assert_equal [:perform], calls
      assert_equal 0, enqueued_jobs.size
    end

    test "one hundred cluster failure wakeups coalesce" do
      100.times do
        StrictPipeline::SchedulerWakeup.request!(
          reason: "cluster_failed",
          wait: 30.seconds
        )
      end

      assert_equal 1, enqueued_jobs.size
    end

    test "actor profile continuous controls are unchanged" do
      assert_equal 5,
                   ActorProfiles::StrictBatchJob::DEFAULT_LIMIT
      assert_equal 5,
                   ActorProfiles::StrictBatchJob::MAX_LIMIT
      assert_equal(
        "actor_profiles:strict_batch:continuous_enabled",
        ActorProfiles::StrictBatchJob::CONTINUOUS_ENABLED_KEY
      )
    end

    private

    def clear_runtime!
      redis_call(
        "DEL",
        StrictPipeline::SchedulerWakeup::WAKEUP_KEY,
        StrictPipeline::SchedulerWakeup::PENDING_KEY,
        StrictPipeline::SchedulerJob::ACTIVE_KEY,
        StrictPipeline::SchedulerJob::ACTIVE_STARTED_AT_KEY
      )
    rescue StandardError
      nil
    end

    def set_wakeup_marker!(due_at: Time.current.to_f)
      redis_call(
        "SET",
        StrictPipeline::SchedulerWakeup::WAKEUP_KEY,
        {
          token: "test-token",
          reason: "test",
          requested_at: Time.current.iso8601(6),
          due_at: due_at
        }.to_json,
        "EX",
        300
      )
    end

    def wakeup_marker_present?
      redis_call(
        "EXISTS",
        StrictPipeline::SchedulerWakeup::WAKEUP_KEY
      ).to_i.positive?
    end

    def set_active_lock!(token)
      redis_call(
        "SET",
        StrictPipeline::SchedulerJob::ACTIVE_KEY,
        token,
        "EX",
        300
      )
    end

    def scheduler_jobs
      enqueued_jobs.select do |job|
        job[:job] == StrictPipeline::SchedulerJob ||
          job["job"] == StrictPipeline::SchedulerJob
      end
    end

    def scheduled_at(job)
      job[:at] || job["at"]
    end

    def redis_call(*args)
      Sidekiq.redis do |redis|
        redis.call(*args)
      end
    end

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      replacement =
        value.respond_to?(:call) ? value : ->(*_args, **_kwargs) { value }

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def with_instance_stub(klass, method_name, replacement)
      original =
        klass.instance_method(method_name)

      klass.define_method(method_name, &replacement)

      yield
    ensure
      klass.define_method(method_name, original)
    end
  end
end
