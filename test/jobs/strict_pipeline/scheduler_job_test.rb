# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerJobTest < ActiveJob::TestCase
    setup do
      clear_runtime!
    end

    teardown do
      clear_runtime!
    end

    test "skips when another scheduler is active" do
      redis_call(
        "SET",
        StrictPipeline::SchedulerJob::ACTIVE_KEY,
        "other-token",
        "EX",
        300
      )

      scheduler_called = false

      with_stubbed(
        StrictPipeline::Scheduler,
        :call,
        -> { scheduler_called = true }
      ) do
        result =
          StrictPipeline::SchedulerJob.new.perform

        assert_equal "skipped", result[:status]
        assert_equal "already_active", result[:reason]
      end

      assert_equal false, scheduler_called
    end

    test "releases active lock in ensure when scheduler succeeds" do
      with_stubbed(
        StrictPipeline::Scheduler,
        :call,
        { ok: true }
      ) do
        with_stubbed(
          StrictPipeline::SchedulerWakeup,
          :request!,
          { enqueued: true }
        ) do
          StrictPipeline::SchedulerJob.new.perform
        end
      end

      assert_equal false, active_lock_present?
    end

    test "releases active lock in ensure when scheduler raises" do
      with_stubbed(
        StrictPipeline::Scheduler,
        :call,
        -> { raise RuntimeError, "boom" }
      ) do
        with_stubbed(
          StrictPipeline::SchedulerWakeup,
          :request!,
          { enqueued: true }
        ) do
          assert_raises(RuntimeError) do
            StrictPipeline::SchedulerJob.new.perform
          end
        end
      end

      assert_equal false, active_lock_present?
    end

    test "different token cannot release active lock" do
      job =
        StrictPipeline::SchedulerJob.new

      redis_call(
        "SET",
        StrictPipeline::SchedulerJob::ACTIVE_KEY,
        "owner-token",
        "EX",
        300
      )

      job.send(
        :release_active_lock,
        "other-token"
      )

      assert_equal "owner-token",
                   redis_call(
                     "GET",
                     StrictPipeline::SchedulerJob::ACTIVE_KEY
                   )
    end

    test "periodic scheduling uses SchedulerWakeup" do
      requests = []

      with_stubbed(
        StrictPipeline::Scheduler,
        :call,
        { ok: true }
      ) do
        with_stubbed(
          StrictPipeline::SchedulerWakeup,
          :request!,
          lambda do |**kwargs|
            requests << kwargs
            { enqueued: true }
          end
        ) do
          StrictPipeline::SchedulerJob.new.perform
        end
      end

      assert_equal 1, requests.size
      assert_equal "periodic",
                   requests.first[:reason]
      assert requests.first[:wait].to_i.positive?
    end

    private

    def active_lock_present?
      redis_call(
        "EXISTS",
        StrictPipeline::SchedulerJob::ACTIVE_KEY
      ).to_i.positive?
    end

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

    def redis_call(*arguments)
      Sidekiq.redis do |redis|
        redis.call(*arguments)
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
  end
end
