# frozen_string_literal: true

require "test_helper"

module System
  class PipelineControllerClusterTransactionProjectionBackfillTest <
    ActiveSupport::TestCase

    def setup
      super
      @old_env = {
        "TANSA_PIPELINE_MODE" => ENV["TANSA_PIPELINE_MODE"],
        "CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED" =>
          ENV["CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"]
      }

      ENV["TANSA_PIPELINE_MODE"] = "development_backfill"
      ENV["CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"] = "1"

      @checkpoint = 10
      @hash = Digest::SHA256.hexdigest("checkpoint")

      ClusterProcessedBlock.create!(
        height: @checkpoint,
        block_hash: @hash,
        status: "processed",
        processed_at: Time.current
      )

      ClusterTransactionProjectionBackfillRun.delete_all
      ClusterTransactionProjectionGeneration.delete_all
      ClusterTransactionProjectionBackfillItem.delete_all
      ClusterTransactionProjectionBackfillAddress.delete_all
    end

    def teardown
      @old_env.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    test "feature flag disabled blocks backfill" do
      ENV["CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"] = "0"

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot: runnable_snapshot
        )

      refute decision[:allowed]
      assert_equal :disabled, decision[:state]
      assert_equal :feature_disabled, decision[:reason]
      assert_includes(
        decision[:failed_constraints],
        :cluster_transaction_projection_backfill_enabled
      )
    end

    test "layer1 catchup phase blocks backfill" do
      plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.except(
              :cluster_transaction_projection_backfill
            ).deep_merge(
              development_backfill: {
                phase: "layer1_catchup"
              }
            )
        )

      refute decision[:allowed]
      assert_equal :phase_layer1_catchup, decision[:reason]
      assert_includes(
        decision[:failed_constraints],
        :development_backfill_downstream_catchup
      )
    end

    test "address spend lag blocks backfill" do
      plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.except(
              :cluster_transaction_projection_backfill
            ).deep_merge(
              address_spend_projection: {
                work_available: true,
                caught_up_to_cluster: false,
                lag: 1
              }
            )
        )

      refute decision[:allowed]
      assert_equal :address_spend_priority, decision[:reason]
    end

    test "actor profile v5 runnable blocks backfill" do
      plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.except(
              :cluster_transaction_projection_backfill
            ).deep_merge(
              actor_profile: {
                pending_work: 1
              }
            )
        )

      refute decision[:allowed]
      assert_equal :actor_profile_v5_priority, decision[:reason]
    end

    test "paused run in downstream catchup is runnable" do
      plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.except(
              :cluster_transaction_projection_backfill
            ).deep_merge(
              development_backfill: {
                phase: "downstream_catchup"
              },
              strict_io: {
                owner: nil
              }
            )
        )

      assert decision[:allowed]
      assert_equal :runnable, decision[:state]
      assert_equal :backfill_work_available, decision[:reason]
      assert_equal 5, decision[:priority]
      assert_equal(
        "cluster_transaction_projection",
        decision.dig(:resources, :queue)
      )
    end

    test "disk guard blocks backfill" do
      run = plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.deep_merge(
              cluster_transaction_projection_backfill: {
                enabled: true,
                active_run_id: run.id,
                active_run_status: run.status,
                remaining_items: run.items.count,
                work_available: true,
                free_disk_bytes: 10,
                projected_free_disk_bytes: 10,
                min_free_disk_bytes: 25.gigabytes
              }
            )
        )

      refute decision[:allowed]
      assert_equal :disk_guard, decision[:reason]
    end

    test "no incomplete run is idle" do
      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.deep_merge(
              cluster_transaction_projection_backfill: {
                active_run_id: nil,
                active_run_status: nil,
                remaining_items: 0,
                work_available: false
              }
            )
        )

      refute decision[:allowed]
      assert_equal :idle_no_run, decision[:state]
      assert_equal :no_incomplete_run, decision[:reason]
    end

    test "planned run with layer1 catchup keeps work available but refused" do
      plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.except(
              :cluster_transaction_projection_backfill
            ).deep_merge(
              development_backfill: {
                phase: "layer1_catchup"
              },
              strict_io: {
                owner: "layer1"
              }
            )
        )

      refute decision[:allowed]
      assert_equal :phase_layer1_catchup, decision[:reason]
      assert_equal :waiting, decision[:state]
      assert PipelineController.work_available?(decision)
      assert_equal(
        true,
        decision.dig(
          :cluster_transaction_projection_backfill,
          :work_available
        )
      )
    end

    test "live snapshot and controller share the same wait reason" do
      plan_run!

      current_snapshot = {
        strict_io: {
          owner: "layer1"
        }
      }

      snapshot =
        ClusterTransactionProjection::OperationalSnapshot.call(
          current_snapshot: current_snapshot
        )
      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot: current_snapshot
        )

      assert_equal "strict_io_busy", snapshot[:wait_reason]
      assert_equal :strict_io_busy, decision[:reason]
    end

    test "planned run with downstream catchup and actor profile backlog blocks on v5 priority" do
      plan_run!

      decision =
        PipelineController.decision(
          :cluster_transaction_projection_backfill,
          current_snapshot:
            runnable_snapshot.except(
              :cluster_transaction_projection_backfill
            ).deep_merge(
              development_backfill: {
                phase: "downstream_catchup"
              },
              layer1: {
                processing: false,
                lag: 0,
                strict_queue_size: 0,
                strict_worker_busy: false
              },
              cluster: {
                lag: 0,
                processing: false,
                strict_queue_size: 0,
                strict_worker_busy: false
              },
              address_spend_projection: {
                work_available: false,
                caught_up_to_cluster: true,
                processing: false,
                failed: false
              },
              actor_profile: {
                pending_work: 5,
                processing: false,
                strict_queue_size: 0,
                strict_worker_busy: false,
                caught_up_to_cluster: true
              },
              strict_io: {
                owner: nil
              }
            )
        )

      refute decision[:allowed]
      assert_equal :actor_profile_v5_priority, decision[:reason]
      assert_equal :waiting, decision[:state]
      assert PipelineController.work_available?(decision)
    end

    private

    def runnable_snapshot
      {
        development_backfill: {
          enabled: true,
          config_valid: true,
          phase: "downstream_catchup"
        },
        bitcoin_core: {
          available: true,
          best_height: 100
        },
        layer1: {
          processed_height: 100,
          lag: 0,
          processing: false,
          buffers_empty: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          catching_up: false
        },
        cluster: {
          processed_height: 100,
          lag: 0,
          global_lag: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          caught_up_to_layer1: true
        },
        address_spend_projection: {
          available: true,
          checkpoint_available: true,
          caught_up_to_cluster: true,
          work_available: false,
          processing: false,
          failed: false
        },
        actor_profile: {
          checkpoint_available: true,
          pending_work: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          caught_up_to_cluster: true
        },
        actor_labels: {
          strict_queue_size: 0,
          strict_worker_busy: false
        },
        strict_io: {
          owner: nil
        },
        cluster_transaction_projection_backfill: {
          enabled: true,
          pipeline_state: "paused",
          wait_reason: nil,
          active_run_id: nil,
          active_run_status: "paused",
          remaining_items: 1,
          current_item: {
            id: 1,
            cluster_id: 2,
            status: "paused",
            stage: "cluster_inputs_received"
          },
          current_stage: "cluster_inputs_received",
          cursor: {},
          free_disk_bytes: 30.gigabytes,
          projected_free_disk_bytes: 30.gigabytes,
          min_free_disk_bytes: 25.gigabytes,
          scheduler_budget_seconds: 30,
          work_available: true
        }
      }
    end

    def plan_run!
      @planned_cluster ||=
        Cluster.create!(composition_version: 1)

      ClusterTransactionProjection::BackfillRunner.plan!(
        cluster_ids: [@planned_cluster.id],
        target_checkpoint_height: @checkpoint,
        target_checkpoint_hash: @hash,
        source: "scheduler_experiment"
      )
    end
  end
end
