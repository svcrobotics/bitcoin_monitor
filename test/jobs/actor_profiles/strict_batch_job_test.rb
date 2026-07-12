# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class StrictBatchJobTest < ActiveJob::TestCase
    include ActiveJob::TestHelper

    setup do
      @original_base_queue_adapter =
        ActiveJob::Base.queue_adapter

      @original_job_queue_adapter =
        ActorProfiles::StrictBatchJob.queue_adapter

      @test_queue_adapter =
        ActiveJob::QueueAdapters::TestAdapter.new

      ActiveJob::Base.queue_adapter =
        @test_queue_adapter

      ActorProfiles::StrictBatchJob.queue_adapter =
        @test_queue_adapter

      clear_actor_profile_runtime!
      clear_enqueued_jobs
      clear_performed_jobs
    end

    teardown do
      begin
        clear_actor_profile_runtime!
        clear_enqueued_jobs
        clear_performed_jobs
      ensure
        ActorProfiles::StrictBatchJob.queue_adapter =
          @original_job_queue_adapter

        ActiveJob::Base.queue_adapter =
          @original_base_queue_adapter
      end
    end

    test "dispatches one batch of five when backlog exists and admission is open" do
      calls = []

      enable_continuous_mode!

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(
          proc do |limit:, progress_token:|
            calls << { limit: limit, progress_token: progress_token }
            completed_batch_result(missing: 5, stale: 0, built: 5)
          end
        ) do
          result =
            perform_job(
              limit: 25,
              reschedule: true
            )

          assert result[:ok]
        end
      end

      assert_equal 1, calls.size
      assert_equal 5, calls.first.fetch(:limit)
      assert_equal 1, enqueued_jobs.size
      assert_equal true, scheduled_marker_present?
    end

    test "runs current batch without scheduling when continuous key is absent" do
      calls = []

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(
          proc do |limit:, progress_token:|
            calls << { limit: limit, progress_token: progress_token }
            completed_batch_result(missing: 5, stale: 0, built: 5)
          end
        ) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert result[:ok]
          assert_equal false, result.dig(:automation, :scheduled_next)
        end
      end

      assert_equal 1, calls.size
      assert_equal 0, enqueued_jobs.size
      assert_equal false, scheduled_marker_present?
    end

    test "runs current batch without scheduling when continuous key is zero" do
      set_continuous_enabled!("0")
      calls = []

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(
          proc do |limit:, progress_token:|
            calls << { limit: limit, progress_token: progress_token }
            completed_batch_result(missing: 5, stale: 0, built: 5)
          end
        ) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert result[:ok]
          assert_equal false, result.dig(:automation, :scheduled_next)
        end
      end

      assert_equal 1, calls.size
      assert_equal 0, enqueued_jobs.size
      assert_equal false, scheduled_marker_present?
    end

    test "does not build or enqueue when a batch is already active" do
      with_redis do |redis|
        redis.call(
          "SET",
          ActorProfiles::StrictBatchJob::LOCK_KEY,
          "active",
          "EX",
          60
        )
      end

      builder_called = false

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(proc { builder_called = true }) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert_equal "skipped", result[:status]
          assert_equal "locked", result[:reason]
        end
      end

      assert_equal false, builder_called
      assert_equal 0, enqueued_jobs.size
    end

    test "ten duplicate attempts while active do not enqueue extra batches" do
      with_redis do |redis|
        redis.call(
          "SET",
          ActorProfiles::StrictBatchJob::LOCK_KEY,
          "active",
          "EX",
          60
        )
      end

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(proc { raise "should not build" }) do
          10.times do
            perform_job(
              limit: 5,
              reschedule: true
            )
          end
        end
      end

      assert_equal 0, enqueued_jobs.size
    end

    test "schedules immediate continuation after a successful batch" do
      enable_continuous_mode!

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(completed_batch_result(missing: 5, stale: 0, built: 5)) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert_equal true, result.dig(:automation, :continuous_mode)
          assert_equal 1, result.dig(:automation, :next_wait_seconds)
        end
      end

      assert_equal 1, enqueued_jobs.size
    end

    test "continues after deferred profiles" do
      enable_continuous_mode!

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(completed_batch_result(missing: 5, stale: 0, built: 3, deferred: 2)) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert result[:ok]
          assert_equal 2, result[:deferred]
          assert_equal 1, result.dig(:automation, :next_wait_seconds)
        end
      end

      assert_equal 1, enqueued_jobs.size
    end

    test "pauses for Layer1 priority and schedules a short retry" do
      enable_continuous_mode!

      with_actor_profile_admission(
        allowed: false,
        work_available: true,
        pending: 10,
        reason: :layer1_priority,
        failed_constraints: [:layer1_strict_queue_idle]
      ) do
        result =
          perform_job(
            limit: 5,
            reschedule: true
          )

        assert_equal "pipeline_controller_denied", result[:reason]
        assert_equal "paused_for_layer1", result.dig(:continuous, :state)
        assert_equal 15, result[:retry_in].to_i
      end

      assert_equal 1, enqueued_jobs.size
    end

    test "pauses for Layer1 priority without retry when continuous key is inactive" do
      set_continuous_enabled!("0")

      with_actor_profile_admission(
        allowed: false,
        work_available: true,
        pending: 10,
        reason: :layer1_priority,
        failed_constraints: [:layer1_strict_queue_idle]
      ) do
        result =
          perform_job(
            limit: 5,
            reschedule: true
          )

        assert_equal "pipeline_controller_denied", result[:reason]
        assert_equal "paused_for_layer1", result.dig(:continuous, :state)
        assert_equal 15, result[:retry_in].to_i
        assert_equal false, result[:scheduled_next]
      end

      assert_equal 0, enqueued_jobs.size
    end

    test "pauses for Cluster priority and schedules a short retry" do
      enable_continuous_mode!

      with_actor_profile_admission(
        allowed: false,
        work_available: true,
        pending: 10,
        reason: :cluster_priority,
        failed_constraints: [:cluster_strict_worker_idle]
      ) do
        result =
          perform_job(
            limit: 5,
            reschedule: true
          )

        assert_equal "paused_for_cluster", result.dig(:continuous, :state)
        assert_equal 15, result[:retry_in].to_i
      end

      assert_equal 1, enqueued_jobs.size
    end

    test "does not build without a certified Cluster checkpoint" do
      enable_continuous_mode!

      builder_called = false

      with_actor_profile_admission(
        allowed: false,
        work_available: true,
        pending: 10,
        reason: :cluster_checkpoint_available,
        failed_constraints: [:cluster_checkpoint_available]
      ) do
        with_batch_builder(proc { builder_called = true }) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert_equal "waiting_for_certified_cluster", result.dig(:continuous, :state)
        end
      end

      assert_equal false, builder_called
      assert_equal 1, enqueued_jobs.size
    end

    test "checks slowly when backlog is empty" do
      enable_continuous_mode!

      with_actor_profile_admission(allowed: true, work_available: false, pending: 0) do
        result =
          perform_job(
            limit: 5,
            reschedule: true
          )

        assert_equal "backlog_empty", result[:reason]
        assert_equal "backlog_empty", result.dig(:continuous, :state)
        assert_equal 60, result[:retry_in].to_i
      end

      assert_equal 1, enqueued_jobs.size
    end

    test "does not retry backlog empty when continuous key is inactive" do
      set_continuous_enabled!("0")

      with_actor_profile_admission(allowed: true, work_available: false, pending: 0) do
        result =
          perform_job(
            limit: 5,
            reschedule: true
          )

        assert_equal "backlog_empty", result[:reason]
        assert_equal "backlog_empty", result.dig(:continuous, :state)
        assert_equal 60, result[:retry_in].to_i
        assert_equal false, result[:scheduled_next]
      end

      assert_equal 0, enqueued_jobs.size
      assert_equal false, scheduled_marker_present?
    end

    test "continues after a recoverable failed batch result" do
      enable_continuous_mode!

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(completed_batch_result(missing: 5, stale: 0, built: 4, failed: 1)) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          refute result[:ok]
          assert_equal 15, result.dig(:automation, :next_wait_seconds)
        end
      end

      assert_equal 1, enqueued_jobs.size
      assert_equal true, scheduled_marker_present?
    end

    test "does not schedule when continuous enabled check fails" do
      calls = []

      with_continuous_enabled_check_failure do
        with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
          with_batch_builder(
            proc do |limit:, progress_token:|
              calls << { limit: limit, progress_token: progress_token }
              completed_batch_result(missing: 5, stale: 0, built: 5)
            end
          ) do
            result =
              perform_job(
                limit: 5,
                reschedule: true
              )

            assert result[:ok]
            assert_equal false, result.dig(:automation, :scheduled_next)
          end
        end
      end

      assert_equal 1, calls.size
      assert_equal 0, enqueued_jobs.size
    end

    test "stops chaining when continuous mode is disabled during the batch" do
      enable_continuous_mode!
      calls = []

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(
          proc do |limit:, progress_token:|
            calls << { limit: limit, progress_token: progress_token }
            set_continuous_enabled!("0")
            completed_batch_result(missing: 5, stale: 0, built: 5)
          end
        ) do
          result =
            perform_job(
              limit: 5,
              reschedule: true
            )

          assert result[:ok]
          assert_equal false, result.dig(:automation, :scheduled_next)
        end
      end

      assert_equal 1, calls.size
      assert_equal 0, enqueued_jobs.size
      assert_equal false, scheduled_marker_present?
    end

    test "reraises exceptions without scheduling an extra retry" do
      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(proc { raise RuntimeError, "boom" }) do
          assert_raises(RuntimeError) do
            perform_job(
              limit: 5,
              reschedule: true
            )
          end
        end
      end

      assert_equal 0, enqueued_jobs.size
      assert_equal false, scheduled_marker_present?
    end

    test "uses batch size five and logical concurrency one" do
      assert_equal 5, ActorProfiles::StrictBatchJob::DEFAULT_LIMIT
      assert_equal 5, ActorProfiles::StrictBatchJob::MAX_LIMIT

      with_actor_profile_admission(allowed: true, work_available: true, pending: 10) do
        with_batch_builder(completed_batch_result(missing: 5, stale: 0, built: 5)) do
          result =
            perform_job(
              limit: 500,
              reschedule: false
            )

          assert_equal 5, result.dig(:automation, :batch_size)
        end
      end
    end

    test "does not trigger ActorBehavior or ActorLabels directly" do
      source =
        File.read(
          Rails.root.join(
            "app/jobs/actor_profiles/strict_batch_job.rb"
          )
        )

      refute_match(/ActorBehaviors::StrictBatchJob/, source)
      refute_match(/ActorLabels::StrictBatchJob/, source)
    end

    private

    def perform_job(limit:, reschedule:)
      ActorProfiles::StrictBatchJob
        .new
        .perform(
          {
            "limit" => limit,
            "reschedule" => reschedule
          }
        )
    end

    def completed_batch_result(
      missing:,
      stale:,
      built:,
      deferred: 0,
      failed: 0
    )
      {
        ok: failed.zero?,
        status: failed.zero? ? "completed" : "failed",
        requested_limit: 5,
        selected: built + deferred + failed,
        processed: built + deferred + failed,
        built: built,
        deferred: deferred,
        failed: failed,
        cluster_tip: 900_000,
        layer1_tip: 900_000,
        actor_profiles_count: 100,
        missing_profiles_count: missing,
        stale_profiles_count: stale,
        duration_ms: 1_000,
        avg_runtime_ms: 200,
        min_runtime_ms: 100,
        max_runtime_ms: 300
      }
    end

    def actor_profile_decision(
      allowed:,
      pending:,
      reason: nil,
      failed_constraints: []
    )
      {
        module: :actor_profile,
        allowed: allowed,
        reason: reason,
        failed_constraints: failed_constraints,
        snapshot: {
          actor_profile: {
            pending_work: pending
          }
        }
      }
    end

    def with_actor_profile_admission(
      allowed:,
      work_available:,
      pending:,
      reason: nil,
      failed_constraints: []
    )
      decision =
        actor_profile_decision(
          allowed: allowed,
          pending: pending,
          reason: reason,
          failed_constraints: failed_constraints
        )

      with_stubbed_singleton_method(
        System::PipelineController,
        :decision,
        proc { |_module_name| decision }
      ) do
        with_stubbed_singleton_method(
          System::PipelineController,
          :work_available?,
          proc { |_decision| work_available }
        ) do
          yield
        end
      end
    end

    def with_batch_builder(result_or_callable)
      callable =
        result_or_callable.respond_to?(:call) ?
          result_or_callable :
          proc { |**_kwargs| result_or_callable }

      with_stubbed_singleton_method(
        ActorProfiles::StrictBatchBuilder,
        :call,
        callable
      ) do
        with_stubbed_singleton_method(
          ActorProfiles::OperationalSnapshot,
          :refresh_from_batch,
          proc { |_result| true }
        ) do
          with_stubbed_singleton_method(
            ActorProfiles::OperationalSnapshot,
            :mark_waiting,
            proc { |**_kwargs| true }
          ) do
            with_stubbed_singleton_method(
              ActorProfiles::BatchProgress,
              :start!,
              proc { |**_kwargs| true }
            ) do
              with_stubbed_singleton_method(
                ActorProfiles::BatchProgress,
                :clear!,
                proc { |**_kwargs| true }
              ) do
                yield
              end
            end
          end
        end
      end
    end

    def clear_actor_profile_runtime!
      with_redis do |redis|
        redis.call(
          "DEL",
          ActorProfiles::StrictBatchJob::LOCK_KEY,
          ActorProfiles::StrictBatchJob::SCHEDULE_KEY,
          ActorProfiles::StrictBatchJob::CONTINUOUS_ENABLED_KEY
        )
      end
    rescue StandardError
      nil
    end

    def enable_continuous_mode!
      set_continuous_enabled!("1")
    end

    def set_continuous_enabled!(value)
      with_redis do |redis|
        redis.call(
          "SET",
          ActorProfiles::StrictBatchJob::CONTINUOUS_ENABLED_KEY,
          value.to_s
        )
      end
    end

    def scheduled_marker_present?
      with_redis do |redis|
        redis
          .call(
            "EXISTS",
            ActorProfiles::StrictBatchJob::SCHEDULE_KEY
          )
          .to_i
          .positive?
      end
    end

    def with_redis(&block)
      Sidekiq.redis(&block)
    end

    def with_continuous_enabled_check_failure
      original =
        Sidekiq.method(:redis)

      proxy_class =
        Struct.new(:delegate) do
          def call(command, *args, **kwargs)
            if command.to_s.upcase == "GET" &&
               args.first ==
                 ActorProfiles::StrictBatchJob::CONTINUOUS_ENABLED_KEY
              raise RuntimeError,
                    "simulated Redis GET failure"
            end

            delegate.call(
              command,
              *args,
              **kwargs
            )
          end

          def method_missing(
            method_name,
            *args,
            **kwargs,
            &block
          )
            if delegate.respond_to?(method_name)
              delegate.public_send(
                method_name,
                *args,
                **kwargs,
                &block
              )
            else
              super
            end
          end

          def respond_to_missing?(
            method_name,
            include_private = false
          )
            delegate.respond_to?(
              method_name,
              include_private
            ) || super
          end
        end

      Sidekiq.define_singleton_method(:redis) do |&block|
        original.call do |redis|
          block.call(
            proxy_class.new(redis)
          )
        end
      end

      yield
    ensure
      Sidekiq.define_singleton_method(:redis) do |&block|
        original.call(&block)
      end
    end

    def with_stubbed_singleton_method(target, method_name, replacement)
      original = target.method(method_name)

      target.define_singleton_method(method_name) do |*args, **kwargs, &block|
        replacement.call(*args, **kwargs, &block)
      end

      yield
    ensure
      target.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
