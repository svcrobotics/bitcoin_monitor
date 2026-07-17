# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorBehaviors
  class StrictBatchJobTest < ActiveJob::TestCase
    include ActorBehaviorTestHelper

    setup do
      clear_lock
      clear_enqueued_jobs
      clear_performed_jobs
    end

    teardown do
      clear_lock
    end

    test "job calls exactly one strict batch" do
      calls = 0
      batch_result = batch_result_hash(selected: 1)

      implementation =
        lambda do |limit:, trigger:, cooperative_guard:|
          calls += 1
          assert_equal "job", trigger
          assert_respond_to cooperative_guard, :call
          batch_result.merge(requested_limit: limit)
        end

      with_actor_behavior_allowed do
        with_stubbed(ActorBehaviors::StrictBatch, :call, implementation) do
          result =
            ActorBehaviors::StrictBatchJob.new.perform(limit: 7)

          assert_equal 1, calls
          assert_equal 7, result[:requested_limit]
        end
      end
    end

    test "job defers when pipeline gives layer1 priority" do
      with_stubbed(
        System::PipelineController,
        :decision,
        {
          allowed: false,
          reason: :layer1_realtime_priority,
          failed_constraints: [:layer1_not_processing]
        }
      ) do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          ->(*) { raise "batch should not run during layer1 priority" }
        ) do
          assert_no_difference -> { ActorBehaviorRun.count } do
            assert_no_difference -> { ActorBehaviorSnapshot.count } do
              result =
                ActorBehaviors::StrictBatchJob.new.perform(limit: 7)

              assert_equal "deferred", result[:status]
              assert_equal "layer1_realtime_priority", result[:reason]
            end
          end
        end
      end
    end

    test "job defers when pipeline gives cluster priority" do
      with_stubbed(
        System::PipelineController,
        :decision,
        {
          allowed: false,
          reason: :cluster_strict_priority,
          failed_constraints: [:cluster_caught_up_to_layer1]
        }
      ) do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          ->(*) { raise "batch should not run during cluster priority" }
        ) do
          result =
            ActorBehaviors::StrictBatchJob.new.perform(limit: 7)

          assert_equal "deferred", result[:status]
          assert_equal "cluster_strict_priority", result[:reason]
        end
      end
    end

    test "job defers when failed constraints expose layer1 priority" do
      with_stubbed(
        System::PipelineController,
        :decision,
        {
          allowed: false,
          reason: :actor_behavior_cooldown,
          failed_constraints: [:layer1_strict_worker_idle]
        }
      ) do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          ->(*) { raise "batch should not run during layer1 priority" }
        ) do
          result =
            ActorBehaviors::StrictBatchJob.new.perform(limit: 7)

          assert_equal "deferred", result[:status]
          assert_equal "layer1_realtime_priority", result[:reason]
        end
      end
    end

    test "job passes cooperative priority guard to batch" do
      guard = nil

      with_actor_behavior_allowed do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          lambda do |limit:, trigger:, cooperative_guard:|
            guard = cooperative_guard
            assert_equal 3, limit
            assert_equal "job", trigger
            batch_result_hash
          end
        ) do
          ActorBehaviors::StrictBatchJob.new.perform(limit: 3)
        end
      end

      assert_respond_to guard, :call
    end

    test "job transmits normalized limit" do
      seen_limit = nil

      with_actor_behavior_allowed do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          lambda do |limit:, trigger:, cooperative_guard:|
            seen_limit = limit
            assert_equal "job", trigger
            assert_respond_to cooperative_guard, :call
            batch_result_hash
          end
        ) do
          ActorBehaviors::StrictBatchJob.new.perform(
            { "limit" => "9" }
          )
        end
      end

      assert_equal 9, seen_limit
    end

    test "job does not reschedule itself" do
      with_actor_behavior_allowed do
        with_stubbed(ActorBehaviors::StrictBatch, :call, batch_result_hash) do
          result =
            ActorBehaviors::StrictBatchJob.new.perform(limit: 1)

          assert_equal "completed", result[:status]
        end
      end

      source =
        Rails.root.join(
          "app/jobs/actor_behaviors/strict_batch_job.rb"
        ).read

      refute_match(/perform_later/, source)
      refute_match(/perform_async/, source)
      refute_match(/perform_in/, source)
    end

    test "job consults pipeline before running batch" do
      calls = 0

      with_stubbed(
        System::PipelineController,
        :decision,
        lambda do |role, **_kwargs|
          calls += 1
          assert_equal :actor_behavior, role
          {
            allowed: true,
            reason: :actor_behavior_work_available,
            failed_constraints: []
          }
        end
      ) do
        with_stubbed(ActorBehaviors::StrictBatch, :call, batch_result_hash) do
          ActorBehaviors::StrictBatchJob.new.perform(limit: 1)
        end
      end

      assert_equal 1, calls
    end

    test "job does not modify scheduler files or require worker" do
      source =
        Rails.root.join(
          "app/jobs/actor_behaviors/strict_batch_job.rb"
        ).read

      refute_match(/StrictPipeline::Scheduler/, source)
      refute_match(/perform_later/, source)
      refute_match(/perform_async/, source)
      refute_match(/perform_in/, source)
      assert_equal "actor_behavior_strict", ActorBehaviors::StrictBatchJob.queue_name
    end

    test "lock prevents simultaneous execution" do
      set_lock("other-token")

      with_stubbed(
        ActorBehaviors::StrictBatch,
        :call,
        ->(*) { raise "batch should not run" }
      ) do
        result =
          ActorBehaviors::StrictBatchJob.new.perform(limit: 1)

        assert_equal "skipped", result[:status]
        assert_equal "lock_busy", result[:reason]
      end
    end

    test "automatic cooldown skips without creating a run" do
      with_actor_behavior_allowed do
        with_stubbed(
          ActorBehaviors::ControlSnapshot,
          :call,
          { cooldown_active: true }
        ) do
          with_stubbed(
            ActorBehaviors::StrictBatch,
            :call,
            ->(*) { raise "batch should not run during cooldown" }
          ) do
            assert_no_difference -> { ActorBehaviorRun.count } do
              result =
                ActorBehaviors::StrictBatchJob.new.perform(
                  {
                    "limit" => 1,
                    "enforce_cooldown" => true
                  }
                )

              assert_equal "skipped", result[:status]
              assert_equal "actor_behavior_cooldown", result[:reason]
            end
          end
        end
      end
    end

    test "lock busy produces no writes" do
      create_certified_actor_profile
      set_lock("other-token")

      assert_no_difference -> { ActorBehaviorSnapshot.count } do
        assert_no_difference -> { ActorBehaviorRun.count } do
          ActorBehaviors::StrictBatchJob.new.perform(limit: 1)
        end
      end
    end

    test "job trigger is persisted by real batch" do
      create_certified_actor_profile

      with_actor_behavior_allowed do
        ActorBehaviors::StrictBatchJob.new.perform(limit: 1)
      end

      assert_equal "job", ActorBehaviorRun.last.trigger
    end

    test "lock is released after success" do
      with_actor_behavior_allowed do
        with_stubbed(ActorBehaviors::StrictBatch, :call, batch_result_hash) do
          ActorBehaviors::StrictBatchJob.new.perform(limit: 1)
        end
      end

      assert_nil current_lock
    end

    test "lock is released after exception" do
      assert_raises RuntimeError do
        with_actor_behavior_allowed do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          ->(**) { raise "boom" }
        ) do
            ActorBehaviors::StrictBatchJob.new.perform(limit: 1)
          end
        end
      end

      assert_nil current_lock
    end

    test "process never releases another token" do
      job =
        ActorBehaviors::StrictBatchJob.new

      set_lock("other-token")
      job.send(:release_lock, "owned-token")

      assert_equal "other-token", current_lock
    end

    test "batch result remains testable" do
      with_actor_behavior_allowed do
        with_stubbed(
          ActorBehaviors::StrictBatch,
          :call,
          batch_result_hash(selected: 3)
        ) do
          result =
            ActorBehaviors::StrictBatchJob.new.perform(limit: 3)

          assert_equal 3, result[:selected]
          assert_equal "actor_behavior_strict", result.dig(:automation, :queue)
        end
      end
    end

    private

    def batch_result_hash(selected: 0)
      {
        ok: true,
        status: "completed",
        requested_limit: 1,
        selected: selected,
        missing_selected: 0,
        stale_selected: 0,
        created: 0,
        updated: 0,
        unchanged: 0,
        deferred: 0,
        failed: 0,
        duration_ms: 1,
        reasons: {}
      }
    end

    def clear_lock
      Sidekiq.redis do |redis|
        redis.del(ActorBehaviors::StrictBatchJob::LOCK_KEY)
      end
    end

    def set_lock(token)
      Sidekiq.redis do |redis|
        redis.set(
          ActorBehaviors::StrictBatchJob::LOCK_KEY,
          token,
          ex: ActorBehaviors::StrictBatchJob::LOCK_TTL_SECONDS
        )
      end
    end

    def current_lock
      Sidekiq.redis do |redis|
        redis.get(ActorBehaviors::StrictBatchJob::LOCK_KEY)
      end
    end

    def with_actor_behavior_allowed
      with_stubbed(
        System::PipelineController,
        :decision,
        {
          allowed: true,
          reason: :actor_behavior_work_available,
          failed_constraints: []
        }
      ) do
        yield
      end
    end

    def with_stubbed(object, method_name, replacement)
      singleton =
        class << object
          self
        end

      original =
        :"#{method_name}_without_actor_behavior_test"

      singleton.alias_method original, method_name

      singleton.define_method(method_name) do |*args, **kwargs, &block|
        if replacement.respond_to?(:call)
          replacement.call(*args, **kwargs, &block)
        else
          replacement
        end
      end

      yield
    ensure
      singleton.alias_method method_name, original
      singleton.remove_method original
    end
  end
end
