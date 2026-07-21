# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class SchedulerTest < ActiveSupport::TestCase
    test "flag disabled enqueues nothing" do
      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => nil) do
        scheduler =
          scheduler_with_counts

        stub_instance(
          scheduler,
          :enqueue,
          ->(_spec) { raise "nothing should be enqueued" }
        ) do
          with_stubbed(
            System::PipelineController,
            :snapshot,
            stable_snapshot
          ) do
            result =
              scheduler.call

            actor_behavior =
              result[:jobs].find { |job| job[:name] == :actor_behavior }

            assert_equal :disabled, actor_behavior[:state]
            refute actor_behavior[:repaired]
          end
        end
      end
    end

    test "disabled decision enqueues nothing" do
      assert_no_actor_behavior_enqueue_for(
        decision_state: :disabled,
        allowed: false,
        work_available: true
      )
    end

    test "blocked decision enqueues nothing" do
      assert_no_actor_behavior_enqueue_for(
        decision_state: :blocked,
        allowed: false,
        work_available: true
      )
    end

    test "idle decision enqueues nothing" do
      assert_no_actor_behavior_enqueue_for(
        decision_state: :idle,
        allowed: true,
        work_available: false
      )
    end

    test "run decision enqueues one actor behavior job with limit" do
      scheduler =
        scheduler_with_counts

      enqueued = []

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec) { enqueued << spec }
      ) do
        with_scheduler_decision(
          actor_behavior_decision(
            state: :run,
            allowed: true,
            work_available: true
          )
        ) do
          result =
            scheduler.call

          actor_behavior =
            result[:jobs].find { |job| job[:name] == :actor_behavior }

          assert actor_behavior[:repaired]
        end
      end

      assert_equal 1, enqueued.size
      assert_equal :actor_behavior, enqueued.first.name
      assert_equal [{ limit: 25, enforce_cooldown: true }], enqueued.first.args
    end

    test "run decision enqueues one actor labels job with cursor persistence" do
      scheduler =
        scheduler_with_counts

      enqueued = []

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec) { enqueued << spec }
      ) do
        with_scheduler_decisions(
          actor_behavior: actor_behavior_decision(
            state: :idle,
            allowed: true,
            work_available: false
          ),
          actor_labels: actor_labels_decision(
            state: :run,
            allowed: true,
            work_available: true
          )
        ) do
          result =
            scheduler.call

          actor_labels =
            result[:jobs].find { |job| job[:name] == :actor_labels }

          assert actor_labels[:repaired]
        end
      end

      assert_equal 1, enqueued.size
      assert_equal :actor_labels, enqueued.first.name
      assert_equal [{ limit: 25, persist_cursor: true }], enqueued.first.args
    end

    test "run decision enqueues one actor profile job when backlog is available" do
      scheduler =
        scheduler_with_counts

      enqueued = []

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec) { enqueued << spec }
      ) do
        with_scheduler_actor_profile_decision(
          runnable_decision(:actor_profile)
        ) do
          result =
            scheduler.call

          actor_profile =
            result[:jobs].find { |job| job[:name] == :actor_profile }

          assert actor_profile[:repaired]
        end
      end

      assert_equal 1, enqueued.size
      assert_equal :actor_profile, enqueued.first.name
      assert_equal(
        [
          {
            limit: 5,
            reschedule: false
          }
        ],
        enqueued.first.args
      )
    end

    test "actor profile lock or scheduled marker prevents duplicate scheduler enqueue" do
      scheduler =
        StrictPipeline::Scheduler.new

      spec =
        StrictPipeline::Scheduler::JOBS.find do |job|
          job.name == :actor_profile
        end

      keys = [
        ActorProfiles::StrictBatchJob::LOCK_KEY,
        ActorProfiles::StrictBatchJob::SCHEDULE_KEY
      ]

      keys.each do |key|
        Sidekiq.redis do |redis|
          redis.del(*keys)
          redis.set(key, "present", ex: 60)
        end

        assert(
          scheduler.send(
            :strict_lock_present?,
            spec
          ),
          "#{key} should block duplicate scheduling"
        )
      end
    ensure
      Sidekiq.redis do |redis|
        redis.del(*keys) if keys
      end
    end

    test "actor profile present active queued scheduled or locked prevents duplicate enqueue" do
      cases = [
        {
          active: {
            "actor_profile_strict" => 1
          }
        },
        {
          queued: {
            "actor_profile_strict" => 1
          }
        },
        {
          scheduled: {
            "actor_profile_strict" => 1
          }
        },
        {
          lock_present: true
        }
      ]

      cases.each do |counts|
        scheduler =
          scheduler_with_counts(**counts)

        stub_instance(
          scheduler,
          :enqueue,
          ->(_spec) { raise "actor profile should not be enqueued twice" }
        ) do
          with_scheduler_actor_profile_decision(
            runnable_decision(:actor_profile)
          ) do
            result =
              scheduler.call

            actor_profile =
              result[:jobs].find { |job| job[:name] == :actor_profile }

            refute actor_profile[:repaired]
            assert actor_profile[:present]
          end
        end
      end
    end

    test "actor labels cooldown prevents enqueue" do
      scheduler =
        scheduler_with_counts

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec) { raise "actor labels should not be enqueued" }
      ) do
        with_scheduler_decisions(
          actor_behavior: actor_behavior_decision(
            state: :idle,
            allowed: true,
            work_available: false
          ),
          actor_labels: actor_labels_decision(
            state: :idle,
            allowed: true,
            work_available: true,
            reason: :actor_labels_cooldown,
            cooldown_active: true
          )
        ) do
          result = scheduler.call
          actor_labels =
            result[:jobs].find { |job| job[:name] == :actor_labels }

          refute actor_labels[:repaired]
          assert_equal :actor_labels_cooldown, actor_labels[:reason]
        end
      end
    end

    test "queue already occupied prevents enqueue" do
      scheduler =
        scheduler_with_counts(queued: { "actor_behavior_strict" => 1 })

      assert_no_enqueue_with_run_decision(scheduler)
    end

    test "worker already active prevents enqueue" do
      scheduler =
        scheduler_with_counts(active: { "actor_behavior_strict" => 1 })

      assert_no_enqueue_with_run_decision(scheduler)
    end

    test "running actor behavior decision prevents enqueue" do
      assert_no_actor_behavior_enqueue_for(
        decision_state: :blocked,
        allowed: false,
        work_available: true,
        reason: :actor_behavior_batch_running
      )
    end

    test "actor behavior lock prevents enqueue" do
      scheduler =
        scheduler_with_counts(lock_present: true)

      assert_no_enqueue_with_run_decision(scheduler)
    end

    test "actor behavior cooldown prevents enqueue" do
      scheduler =
        scheduler_with_counts

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec) { raise "actor behavior should not be enqueued" }
      ) do
        with_scheduler_decision(
          actor_behavior_decision(
            state: :idle,
            allowed: true,
            work_available: true,
            reason: :actor_behavior_cooldown,
            cooldown_active: true
          )
        ) do
          result = scheduler.call
          actor_behavior =
            result[:jobs].find { |job| job[:name] == :actor_behavior }

          refute actor_behavior[:repaired]
          assert_equal :actor_behavior_cooldown, actor_behavior[:reason]
        end
      end
    end

    test "scheduled actor behavior job prevents enqueue" do
      scheduler =
        scheduler_with_counts(scheduled: { "actor_behavior_strict" => 1 })

      assert_no_enqueue_with_run_decision(scheduler)
    end

    test "stale actor behavior run flag prevents enqueue" do
      scheduler =
        scheduler_with_counts

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec) { raise "actor behavior should not be enqueued" }
      ) do
        with_scheduler_decision(
          actor_behavior_decision(
            state: :run,
            allowed: true,
            work_available: true,
            stale_running_run: true
          )
        ) do
          result = scheduler.call
          actor_behavior =
            result[:jobs].find { |job| job[:name] == :actor_behavior }

          refute actor_behavior[:repaired]
        end
      end
    end

    test "scheduler does not use perform_in or self rescheduling" do
      source =
        Rails.root.join(
          "app/services/strict_pipeline/scheduler.rb"
        ).read

      refute_match(/perform_in/, source)
      refute_match(/set\(wait:/, source)

      actor_labels_source =
        Rails.root.join(
          "app/jobs/actor_labels/strict_batch_job.rb"
        ).read

      refute_match(/set\(wait:/, actor_labels_source)
    end

    test "strict roles keep their existing worker declarations" do
      jobs =
        StrictPipeline::Scheduler::JOBS

      assert_equal(
        "layer1_strict",
        jobs.find { |job| job.name == :layer1 }.queue
      )
      assert_equal(
        "cluster_strict",
        jobs.find { |job| job.name == :cluster }.queue
      )
      assert_equal(
        "actor_profile_strict",
        jobs.find { |job| job.name == :actor_profile }.queue
      )
      assert_equal(
        "actor_behavior_strict",
        jobs.find { |job| job.name == :actor_behavior }.queue
      )
      assert_equal(
        "actor_labels_strict",
        jobs.find { |job| job.name == :actor_labels }.queue
      )
    end

    test "decision only creates no actor behavior data" do
      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => nil) do
        scheduler =
          scheduler_with_counts

        with_stubbed(
          System::PipelineController,
          :snapshot,
          stable_snapshot
        ) do
          assert_no_difference -> { ActorBehaviorRun.count } do
            assert_no_difference -> { ActorBehaviorSnapshot.count } do
              scheduler.call
            end
          end
        end
      end
    end

    test "layer1 priority with lag above budget acquires strict io lease before cluster" do
      scheduler =
        scheduler_without_sidekiq_counts

      enqueued = []
      acquired = []
      lease_for = method(:lease)

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          lambda do |owner, **_kwargs|
            acquired << owner.to_s
            lease_for.call(owner)
          end
        ) do
          with_scheduler_decisions_for(
            layer1: runnable_decision(:layer1_realtime),
            cluster: runnable_decision(:cluster)
          ) do
            scheduler.call
          end
        end
      end

      assert_equal ["layer1"], acquired
      assert_equal [[:layer1, "layer1"]], enqueued
    end

    test "cluster can acquire strict io lease when layer1 is idle and work exists" do
      scheduler =
        scheduler_without_sidekiq_counts

      enqueued = []
      lease_for = method(:lease)

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(owner, **_kwargs) { lease_for.call(owner) }
        ) do
          with_scheduler_decisions_for(
            layer1: idle_decision(:layer1, stable_snapshot),
            cluster: runnable_decision(:cluster)
          ) do
            scheduler.call
          end
        end
      end

      assert_equal [[:cluster, "cluster"]], enqueued
    end

    test "serialized scheduler never enqueues two strict io owners in one pass" do
      with_env("TANSA_STRICT_IO_MODE" => "serialized") do
        scheduler =
          scheduler_without_sidekiq_counts

        enqueued = []
        lease_for = method(:lease)

        stub_instance(
          scheduler,
          :enqueue,
          ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :acquire,
            ->(owner, **_kwargs) { lease_for.call(owner) }
          ) do
            with_scheduler_decisions_for(
              layer1: runnable_decision(:layer1_realtime),
              cluster: runnable_decision(:cluster)
            ) do
              scheduler.call
            end
          end
        end

        assert_equal [[:layer1, "layer1"]], enqueued
      end
    end

    test "concurrent ssd scheduler enqueues layer1 and cluster in one pass" do
      with_env("TANSA_STRICT_IO_MODE" => "concurrent_ssd") do
        scheduler =
          scheduler_without_sidekiq_counts

        enqueued = []
        lease_for = method(:lease)

        stub_instance(
          scheduler,
          :enqueue,
          ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :acquire,
            ->(owner, **_kwargs) { lease_for.call(owner) }
          ) do
            with_scheduler_decisions_for(
              layer1: runnable_decision(:layer1_realtime),
              cluster: runnable_decision(:cluster)
            ) do
              scheduler.call
            end
          end
        end

        assert_equal(
          [[:layer1, "layer1"], [:cluster, "cluster"]],
          enqueued
        )
      end
    end

    test "concurrent ssd scheduler does not refuse cluster only because layer1 worker is active" do
      with_env("TANSA_STRICT_IO_MODE" => "concurrent_ssd") do
        scheduler =
          scheduler_without_sidekiq_counts(
            active: {
              "layer1_strict" => 1
            }
          )

        enqueued = []
        lease_for = method(:lease)

        stub_instance(
          scheduler,
          :enqueue,
          ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :acquire,
            ->(owner, **_kwargs) { lease_for.call(owner) }
          ) do
            with_scheduler_decisions_for(
              layer1: idle_decision(:layer1, stable_snapshot),
              cluster: runnable_decision(:cluster)
            ) do
              scheduler.call
            end
          end
        end

        assert_equal [[:cluster, "cluster"]], enqueued
      end
    end

    test "concurrent ssd scheduler does not refuse layer1 only because cluster worker is active" do
      with_env("TANSA_STRICT_IO_MODE" => "concurrent_ssd") do
        scheduler =
          scheduler_without_sidekiq_counts(
            active: {
              "cluster_strict" => 1
            }
          )

        enqueued = []
        lease_for = method(:lease)

        stub_instance(
          scheduler,
          :enqueue,
          ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :acquire,
            ->(owner, **_kwargs) { lease_for.call(owner) }
          ) do
            with_scheduler_decisions_for(
              layer1: runnable_decision(:layer1_realtime),
              cluster: idle_decision(:cluster, stable_snapshot)
            ) do
              scheduler.call
            end
          end
        end

        assert_equal [[:layer1, "layer1"]], enqueued
      end
    end

    test "scheduler refuses cluster while layer1 worker remains active even with expired redis lease" do
      scheduler =
        scheduler_without_sidekiq_counts(
          active: {
            "layer1_strict" => 1
          }
        )

      acquired = false

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "cluster must not be enqueued" }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(_owner, **_kwargs) { acquired = true }
        ) do
          with_scheduler_decisions_for(
            layer1: idle_decision(:layer1, stable_snapshot),
            cluster: runnable_decision(:cluster)
          ) do
            result = scheduler.call

            cluster =
              result[:jobs].find { |job| job[:name] == :cluster }

            assert_equal :strict_io_lease_denied, cluster[:reason]
            refute cluster[:repaired]
          end
        end
      end

      assert_equal false, acquired
    end

    test "scheduler refuses layer1 while cluster worker remains active even with expired redis lease" do
      scheduler =
        scheduler_without_sidekiq_counts(
          active: {
            "cluster_strict" => 1
          }
        )

      acquired = false

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 must not be enqueued" }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(_owner, **_kwargs) { acquired = true }
        ) do
          with_scheduler_decisions_for(
            layer1: runnable_decision(:layer1_realtime),
            cluster: idle_decision(:cluster, stable_snapshot)
          ) do
            result = scheduler.call

            layer1 =
              result[:jobs].find { |job| job[:name] == :layer1 }

            assert_equal :strict_io_lease_denied, layer1[:reason]
            refute layer1[:repaired]
          end
        end
      end

      assert_equal false, acquired
    end

    test "layer1 worker settling schedules short retry instead of waiting periodic cycle" do
      snapshot =
        layer1_settling_snapshot

      scheduler =
        scheduler_without_sidekiq_counts(
          active: {
            "layer1_strict" => 1
          }
        )

      requests = []

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be enqueued while worker is still active" }
      ) do
        with_stubbed(
          StrictPipeline::SchedulerWakeup,
          :request!,
          lambda do |**kwargs|
            requests << kwargs
            { enqueued: true }
          end
        ) do
          with_layer1_scheduler_snapshot(snapshot) do
            result =
              scheduler.call

            layer1 =
              result[:jobs].find { |job| job[:name] == :layer1 }

            assert_equal true, layer1[:settling_retry]
            refute layer1[:repaired]
          end
        end
      end

      assert_equal 1, requests.size
      assert_equal "layer1_worker_state_settling",
                   requests.first[:reason]
      assert_equal 2, requests.first[:wait].to_i
    end

    test "layer1 real processing does not schedule worker settling retry" do
      snapshot =
        layer1_settling_snapshot.merge(
          layer1:
            layer1_settling_snapshot[:layer1].merge(
              processing: true
            )
        )

      scheduler =
        scheduler_without_sidekiq_counts(
          active: {
            "layer1_strict" => 1
          }
        )

      requests = []

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be enqueued while processing" }
      ) do
        with_stubbed(
          StrictPipeline::SchedulerWakeup,
          :request!,
          lambda do |**kwargs|
            requests << kwargs
            { enqueued: true }
          end
        ) do
          with_layer1_scheduler_snapshot(snapshot) do
            result =
              scheduler.call

            layer1 =
              result[:jobs].find { |job| job[:name] == :layer1 }

            assert_equal false, layer1[:settling_retry]
            refute layer1[:repaired]
          end
        end
      end

      assert_empty requests
    end

    test "lag twenty three active catchup with empty queue enqueues one layer1 job" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts

      enqueued = []
      lease_for = method(:lease)

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :acquire,
          ->(owner, **_kwargs) { lease_for.call(owner) }
        ) do
          with_layer1_scheduler_snapshot(snapshot) do
            result =
              scheduler.call

            layer1 =
              result[:jobs].find { |job| job[:name] == :layer1 }

            assert layer1[:repaired]
          end
        end
      end

      assert_equal [[:layer1, "layer1"]], enqueued
    end

    test "repeated layer1 scheduler pass does not enqueue duplicate when queued" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts(
          queued: {
            "layer1_strict" => 1
          }
        )

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be duplicated" }
      ) do
        with_layer1_scheduler_snapshot(snapshot) do
          result =
            scheduler.call

          layer1 =
            result[:jobs].find { |job| job[:name] == :layer1 }

          assert layer1[:present]
          refute layer1[:repaired]
        end
      end
    end

    test "layer1 active worker prevents duplicate enqueue" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts(
          active: {
            "layer1_strict" => 1
          }
        )

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be duplicated" }
      ) do
        with_layer1_scheduler_snapshot(snapshot) do
          result =
            scheduler.call

          layer1 =
            result[:jobs].find { |job| job[:name] == :layer1 }

          assert layer1[:present]
          refute layer1[:repaired]
        end
      end
    end

    test "layer1 scheduled job prevents duplicate enqueue" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts(
          scheduled: {
            "layer1_strict" => 1
          }
        )

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be duplicated" }
      ) do
        with_layer1_scheduler_snapshot(snapshot) do
          result =
            scheduler.call

          layer1 =
            result[:jobs].find { |job| job[:name] == :layer1 }

          assert layer1[:present]
          refute layer1[:repaired]
        end
      end
    end

    test "layer1 retry job prevents duplicate enqueue" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts(
          retrying: {
            "layer1_strict" => 1
          }
        )

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be duplicated" }
      ) do
        with_layer1_scheduler_snapshot(snapshot) do
          result =
            scheduler.call

          layer1 =
            result[:jobs].find { |job| job[:name] == :layer1 }

          assert layer1[:present]
          assert_equal 1, layer1[:retry]
          refute layer1[:repaired]
        end
      end
    end

    test "valid strict io lease prevents duplicate layer1 enqueue" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec, lease: nil) { raise "layer1 should not be duplicated" }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :compatible_with_current?,
          false
        ) do
          with_layer1_scheduler_snapshot(snapshot) do
            result =
              scheduler.call

            layer1 =
              result[:jobs].find { |job| job[:name] == :layer1 }

            assert layer1[:present]
            refute layer1[:repaired]
          end
        end
      end
    end

    test "expired strict io lease with no active work is recovered by acquiring a new lease" do
      snapshot =
        layer1_catchup_snapshot(lag: 23)

      scheduler =
        scheduler_without_sidekiq_counts

      enqueued = []
      acquired = []
      lease_for = method(:lease)

      stub_instance(
        scheduler,
        :enqueue,
        ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
      ) do
        with_stubbed(
          StrictPipeline::StrictIoLease,
          :current,
          nil
        ) do
          with_stubbed(
            StrictPipeline::StrictIoLease,
            :acquire,
            lambda do |owner, **_kwargs|
              acquired << owner.to_s
              lease_for.call(owner)
            end
          ) do
            with_layer1_scheduler_snapshot(snapshot) do
              scheduler.call
            end
          end
        end
      end

      assert_equal ["layer1"], acquired
      assert_equal [[:layer1, "layer1"]], enqueued
    end

    test "cluster transaction backfill flag disabled is not considered by scheduler" do
      with_env(
        "CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED" => nil
      ) do
        scheduler =
          scheduler_without_sidekiq_counts

        with_stubbed(
          System::PipelineController,
          :snapshot,
          stable_snapshot
        ) do
          result =
            scheduler.call

          refute_includes(
            result[:jobs].map { |job| job[:name] },
            :cluster_transaction_projection_backfill
          )
        end
      end
    end

    test "cluster transaction backfill enqueues one slice when enabled and runnable" do
      with_env(
        "CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED" => "1"
      ) do
        scheduler =
          scheduler_without_sidekiq_counts

        enqueued = []

        stub_instance(
          scheduler,
          :enqueue,
          ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
        ) do
          with_stubbed(
            ClusterTransactionProjection::BackfillSliceJob,
            :lock_present?,
            false
          ) do
            with_scheduler_decision_map(
              cluster_transaction_projection_backfill:
                runnable_decision(
                  :cluster_transaction_projection_backfill
                )
            ) do
              result =
                scheduler.call

              backfill =
                result[:jobs].find do |job|
                  job[:name] ==
                    :cluster_transaction_projection_backfill
                end

              assert backfill[:repaired]
            end
          end
        end

        assert_equal(
          [
            [
              :cluster_transaction_projection_backfill,
              nil
            ]
          ],
          enqueued
        )
      end
    end

    test "cluster transaction backfill refused by phase does not enqueue" do
      with_env(
        "CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED" => "1"
      ) do
        scheduler =
          scheduler_without_sidekiq_counts

        enqueued = []

        stub_instance(
          scheduler,
          :enqueue,
          ->(spec, lease: nil) { enqueued << [spec.name, lease&.owner] }
        ) do
          with_scheduler_decision_map(
            cluster_transaction_projection_backfill: {
              module: :cluster_transaction_projection_backfill,
              allowed: false,
              state: :waiting,
              reason: :phase_layer1_catchup,
              work_available: true
            }
          ) do
            result =
              scheduler.call

            backfill =
              result[:jobs].find do |job|
                job[:name] ==
                  :cluster_transaction_projection_backfill
              end

            refute backfill[:repaired]
            assert_equal :phase_layer1_catchup, backfill[:reason]
            assert backfill[:work_available]
          end
        end

        assert_equal [], enqueued
      end
    end

    test "cluster transaction backfill marker prevents duplicate enqueue" do
      with_env(
        "CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED" => "1"
      ) do
        scheduler =
          scheduler_without_sidekiq_counts

        stub_instance(
          scheduler,
          :enqueue,
          ->(_spec, lease: nil) { raise "backfill should not duplicate" }
        ) do
          with_stubbed(
            ClusterTransactionProjection::BackfillSliceJob,
            :lock_present?,
            true
          ) do
            with_scheduler_decision_map(
              cluster_transaction_projection_backfill:
                runnable_decision(
                  :cluster_transaction_projection_backfill
                )
            ) do
              result =
                scheduler.call

              backfill =
                result[:jobs].find do |job|
                  job[:name] ==
                    :cluster_transaction_projection_backfill
                end

              assert backfill[:present]
              refute backfill[:repaired]
            end
          end
        end
      end
    end

    private

    def layer1_catchup_snapshot(lag:)
      stable_snapshot.deep_merge(
        development_backfill: {
          enabled: true,
          config_valid: true,
          phase: "layer1_catchup"
        },
        strict_io: {
          owner: nil
        },
        layer1: {
          lag: lag,
          processing: false,
          buffers: {
            outputs: 0,
            spent: 0
          },
          buffers_empty: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          catching_up: true
        }
      )
    end

    def layer1_settling_snapshot
      stable_snapshot.merge(
        strict_io: {
          owner: nil
        },
        layer1:
          stable_snapshot[:layer1].merge(
            lag: 1,
            processing: false,
            strict_queue_size: 0,
            strict_worker_busy: true,
            catching_up: false
          )
      )
    end

    def with_layer1_scheduler_snapshot(snapshot)
      idle =
        method(:idle_decision)
      runnable =
        method(:runnable_decision)

      with_stubbed(
        System::PipelineController,
        :snapshot,
        snapshot
      ) do
        with_stubbed(
          System::PipelineController,
          :decision,
          lambda do |name, current_snapshot: nil|
            if name == :layer1
              runnable.call(:layer1_realtime).merge(
                snapshot: current_snapshot
              )
            else
              idle.call(name, current_snapshot)
            end
          end
        ) do
          with_stubbed(
            System::PipelineController,
            :work_available?,
            ->(decision) { decision[:work_available] == true }
          ) do
            yield
          end
        end
      end
    end

    def scheduler_without_sidekiq_counts(active: {}, queued: {}, scheduled: {}, retrying: {})
      scheduler =
        StrictPipeline::Scheduler.new

      scheduler.define_singleton_method(:active_count) do |queue|
        active.fetch(queue, 0)
      end
      scheduler.define_singleton_method(:queued_count) do |queue|
        queued.fetch(queue, 0)
      end
      scheduler.define_singleton_method(:scheduled_count) do |queue|
        scheduled.fetch(queue, 0)
      end
      scheduler.define_singleton_method(:retry_count) do |queue|
        retrying.fetch(queue, 0)
      end
      scheduler.define_singleton_method(:publish_runtime_status) { true }
      scheduler.define_singleton_method(:ensure_actor_labels_worker_capability) { true }
      scheduler.define_singleton_method(:run_anomaly_watchdog) do
        {
          ok: true
        }
      end

      scheduler
    end

    def with_scheduler_decisions_for(layer1:, cluster:)
      idle =
        method(:idle_decision)

      with_stubbed(
        System::PipelineController,
        :snapshot,
        stable_snapshot
      ) do
        with_stubbed(StrictPipeline::StrictIoLease, :current, nil) do
          with_stubbed(
            System::PipelineController,
            :decision,
            lambda do |name, current_snapshot: nil|
              case name
              when :layer1
                layer1.merge(snapshot: current_snapshot)
              when :cluster
                cluster.merge(snapshot: current_snapshot)
              else
                idle.call(name, current_snapshot)
              end
            end
          ) do
            with_stubbed(
              System::PipelineController,
              :work_available?,
              ->(decision) { decision[:work_available] == true }
            ) do
              yield
            end
          end
        end
      end
    end

    def with_scheduler_decision_map(decisions)
      idle =
        method(:idle_decision)

      with_stubbed(
        System::PipelineController,
        :snapshot,
        stable_snapshot
      ) do
        with_stubbed(StrictPipeline::StrictIoLease, :current, nil) do
          with_stubbed(
            System::PipelineController,
            :decision,
            lambda do |name, current_snapshot: nil|
              key =
                name == :layer1 ? :layer1_realtime : name

              decision =
                decisions[key]

              if decision
                decision.merge(snapshot: current_snapshot)
              else
                idle.call(name, current_snapshot)
              end
            end
          ) do
            with_stubbed(
              System::PipelineController,
              :work_available?,
              ->(decision) { decision[:work_available] == true }
            ) do
              yield
            end
          end
        end
      end
    end

    def runnable_decision(module_name)
      {
        module: module_name,
        allowed: true,
        state: :runnable,
        reason: nil,
        work_available: true,
        snapshot: stable_snapshot
      }
    end

    def lease(owner)
      StrictPipeline::StrictIoLease::Lease.new(
        owner: owner.to_s,
        token: "#{owner}-token",
        acquired_at: Time.current,
        expires_at: 2.minutes.from_now
      )
    end

    def assert_no_actor_behavior_enqueue_for(
      decision_state:,
      allowed:,
      work_available:,
      reason: nil
    )
      scheduler =
        scheduler_with_counts

      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec) { raise "actor behavior should not be enqueued" }
      ) do
        with_scheduler_decision(
          actor_behavior_decision(
            state: decision_state,
            allowed: allowed,
            work_available: work_available,
            reason: reason
          )
        ) do
          result =
            scheduler.call

          actor_behavior =
            result[:jobs].find { |job| job[:name] == :actor_behavior }

          assert_equal decision_state, actor_behavior[:state]
          refute actor_behavior[:repaired]
        end
      end
    end

    def assert_no_enqueue_with_run_decision(scheduler)
      stub_instance(
        scheduler,
        :enqueue,
        ->(_spec) { raise "actor behavior should not be enqueued" }
      ) do
        with_scheduler_decision(
          actor_behavior_decision(
            state: :run,
            allowed: true,
            work_available: true
          )
        ) do
          result =
            scheduler.call

          actor_behavior =
            result[:jobs].find { |job| job[:name] == :actor_behavior }

          refute actor_behavior[:repaired]
        end
      end
    end

    def scheduler_with_counts(active: {}, queued: {}, scheduled: {}, retrying: {}, lock_present: false)
      scheduler =
        StrictPipeline::Scheduler.new

      scheduler.define_singleton_method(:active_count) do |queue|
        active.fetch(queue, 0)
      end

      scheduler.define_singleton_method(:queued_count) do |queue|
        queued.fetch(queue, 0)
      end

      scheduler.define_singleton_method(:scheduled_count) do |queue|
        scheduled.fetch(queue, 0)
      end

      scheduler.define_singleton_method(:retry_count) do |queue|
        retrying.fetch(queue, 0)
      end

      scheduler.define_singleton_method(:strict_lock_present?) do |_spec|
        lock_present
      end

      scheduler
    end

    def with_scheduler_decision(actor_behavior)
      with_scheduler_decisions(actor_behavior: actor_behavior) do
        yield
      end
    end

    def with_scheduler_actor_profile_decision(actor_profile)
      idle =
        method(:idle_decision)

      with_stubbed(
        System::PipelineController,
        :snapshot,
        stable_snapshot
      ) do
        with_stubbed(
          System::PipelineController,
          :decision,
          lambda do |name, current_snapshot: nil|
            if name == :actor_profile
              actor_profile.merge(snapshot: current_snapshot)
            else
              idle.call(name, current_snapshot)
            end
          end
        ) do
          with_stubbed(
            System::PipelineController,
            :work_available?,
            ->(decision) { decision[:work_available] == true }
          ) do
            yield
          end
        end
      end
    end

    def with_scheduler_decisions(actor_behavior:, actor_labels: nil)
      idle =
        method(:idle_decision)

      with_stubbed(
        System::PipelineController,
        :snapshot,
        stable_snapshot
      ) do
        with_stubbed(
          System::PipelineController,
          :decision,
          lambda do |name, current_snapshot: nil|
            if name == :actor_behavior
              actor_behavior.merge(snapshot: current_snapshot)
            elsif name == :actor_labels && actor_labels
              actor_labels.merge(snapshot: current_snapshot)
            else
              idle.call(name, current_snapshot)
            end
          end
        ) do
          with_stubbed(
            System::PipelineController,
            :work_available?,
            ->(decision) { decision[:work_available] == true }
          ) do
            yield
          end
        end
      end
    end

    def actor_behavior_decision(
      state:,
      allowed:,
      work_available:,
      reason: nil,
      cooldown_active: false,
      stale_running_run: false
    )
      {
        module: :actor_behavior,
        allowed: allowed,
        state: state,
        reason: reason,
        work_available: work_available,
        actor_behavior: {
          auto_enabled: true,
          cooldown_active: cooldown_active,
          batch_running: false,
          stale_running_run: stale_running_run
        },
        snapshot: stable_snapshot
      }
    end

    def actor_labels_decision(
      state:,
      allowed:,
      work_available:,
      reason: nil,
      cooldown_active: false
    )
      {
        module: :actor_labels,
        allowed: allowed,
        state: state,
        reason: reason,
        work_available: work_available,
        actor_labels: {
          cooldown_active: cooldown_active,
          lock_present: false
        },
        snapshot: stable_snapshot
      }
    end

    def idle_decision(name, snapshot)
      {
        module: name,
        allowed: false,
        state: :idle,
        reason: nil,
        work_available: false,
        snapshot: snapshot
      }
    end

    def stable_snapshot
      {
        bitcoin_core: {
          available: true
        },
        layer1: {
          lag: 0,
          processing: false,
          buffers_empty: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          catching_up: false
        },
        cluster: {
          lag: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          caught_up_to_layer1: true
        },
        address_spend_projection: {
          available: true,
          source_available: true,
          worker_present: true,
          checkpoint_height: 956_250,
          checkpoint_available: true,
          caught_up_to_cluster: true,
          lag: 0,
          next_record_height: nil,
          work_available: false,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          strict_active: false,
          failed: false,
          status: "healthy"
        },

        actor_profile: {
          checkpoint_available: true,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          pending_work: 0,
          caught_up_to_cluster: true
        },
        actor_labels: {
          strict_queue_size: 0,
          strict_worker_busy: false
        }
      }
    end

    def with_env(values)
      old_values = {}

      values.each_key do |key|
        old_values[key] =
          ENV[key]
      end

      values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end

      yield
    ensure
      old_values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
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
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def stub_instance(object, method_name, value)
      singleton =
        class << object
          self
        end

      original =
        object.method(method_name)

      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      singleton.define_method(method_name, &replacement)

      yield
    ensure
      singleton.define_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
