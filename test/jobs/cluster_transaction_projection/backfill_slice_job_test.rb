# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class BackfillSliceJobTest < ActiveJob::TestCase
    def teardown
      Sidekiq.redis do |redis|
        redis.del(
          BackfillSliceJob::LOCK_KEY,
          BackfillSliceJob::SCHEDULE_KEY
        )
      end
    end

    test "refused pipeline decision does not acquire lease" do
      acquired = false

      with_stubbed(
        System::PipelineController,
        :decision,
        {
          allowed: false,
          state: :waiting,
          reason: :layer1_priority,
          failed_constraints: [:layer1_priority]
        }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(_owner, **_kwargs) { acquired = true }
        ) do
          result =
            BackfillSliceJob.perform_now

          assert_equal false, result[:ok]
          assert_equal :layer1_priority, result[:reason]
        end
      end

      assert_equal false, acquired
    end

    test "executes bounded runner and releases strict io lease" do
      run = create_run
      lease = lease_for("cluster_transaction_projection")
      released = []
      runner_kwargs = nil

      with_allowed_decision(run) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(_owner, **_kwargs) { lease }
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :release,
            lambda do |owner:, token:, **_kwargs|
              released << [owner, token]
              true
            end
          ) do
            with_stubbed(
              BackfillRunner,
              :call,
              lambda do |**kwargs|
                runner_kwargs = kwargs

                BackfillRunner::Result.new(
                  ok: true,
                  reason: :budget_exhausted,
                  run: run,
                  chunks_processed: 2,
                  elapsed_ms: 29_000,
                  last_chunk_ms: 12_000,
                  facts_inserted: 3,
                  facts_updated: 4,
                  rows_scanned: 5,
                  pause_reason: :budget_exhausted
                )
              end
            ) do
              result =
                BackfillSliceJob.perform_now

              assert_equal true, result[:ok]
              assert_equal 2, result[:chunks_executed]
              assert_equal :budget_exhausted, result[:pause_reason]
            end
          end
        end
      end

      assert_equal run.id, runner_kwargs[:run_id]
      assert_equal lease, runner_kwargs[:external_lease]
      assert_equal 30, runner_kwargs[:budget_seconds]
      assert_equal(
        [
          [
            "cluster_transaction_projection",
            "cluster_transaction_projection-token"
          ]
        ],
        released
      )
    end

    test "preemption callback delegates to pipeline controller" do
      run = create_run
      lease = lease_for("cluster_transaction_projection")
      preemption_reason = nil

      with_allowed_decision(run) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(_owner, **_kwargs) { lease }
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :release,
            ->(**_kwargs) { true }
          ) do
            with_stubbed(
              System::PipelineController,
              :cluster_transaction_projection_backfill_preemption_reason,
              :actor_profile_v5_priority
            ) do
              with_stubbed(
                BackfillRunner,
                :call,
                lambda do |**kwargs|
                  preemption_reason =
                    kwargs[:preemption_check].call(run)

                  BackfillRunner::Result.new(
                    ok: true,
                    reason: :actor_profile_v5_priority,
                    run: run,
                    chunks_processed: 1,
                    elapsed_ms: 1000,
                    last_chunk_ms: 1000,
                    facts_inserted: 0,
                    facts_updated: 0,
                    rows_scanned: 0,
                    pause_reason: :actor_profile_v5_priority
                  )
                end
              ) do
                result =
                  BackfillSliceJob.perform_now

                assert_equal :actor_profile_v5_priority,
                             result[:pause_reason]
              end
            end
          end
        end
      end

      assert_equal(
        :actor_profile_v5_priority,
        preemption_reason
      )
    end

    private

    def create_run
      ClusterTransactionProjectionBackfillRun.create!(
        target_checkpoint_height: 10,
        target_checkpoint_hash: "hash",
        status: "paused",
        source: "test"
      )
    end

    def with_allowed_decision(run)
      with_stubbed(
        System::PipelineController,
        :decision,
        {
          allowed: true,
          state: :runnable,
          reason: :backfill_work_available,
          failed_constraints: [],
          cluster_transaction_projection_backfill: {
            active_run_id: run.id
          }
        }
      ) do
        with_stubbed(
          System::PipelineController,
          :work_available?,
          true
        ) do
          yield
        end
      end
    end

    def lease_for(owner)
      StrictPipeline::StrictIoLease::Lease.new(
        owner: owner,
        token: "#{owner}-token",
        acquired_at: Time.current,
        expires_at: 1.minute.from_now
      )
    end

    def with_stubbed(object, method_name, value = nil)
      original =
        object.method(method_name)

      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name, original)
    end
  end
end
