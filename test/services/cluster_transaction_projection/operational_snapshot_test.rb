# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class OperationalSnapshotTest < ActiveSupport::TestCase
    def setup
      StrictPipeline::StrictIoLease.clear!
      @old_enabled =
        ENV["CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"]
      ENV["CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"] = "1"
      @checkpoint = 10
      @hash = Digest::SHA256.hexdigest("checkpoint")

      ClusterProcessedBlock.create!(
        height: @checkpoint,
        block_hash: @hash,
        status: "processed",
        processed_at: Time.current
      )
    end

    teardown do
      if @old_enabled.nil?
        ENV.delete("CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED")
      else
        ENV["CLUSTER_TRANSACTION_PROJECTION_BACKFILL_ENABLED"] =
          @old_enabled
      end
      StrictPipeline::StrictIoLease.clear!
    end

    test "no incomplete run reports no_incomplete_run" do
      snapshot =
        OperationalSnapshot.call(
          current_snapshot:
            {
              development_backfill: {
                phase: "layer1_catchup"
              },
              strict_io: {
                owner: "layer1"
              }
            }
        )

      refute snapshot[:work_available]
      assert_equal "idle_no_run", snapshot[:pipeline_state]
      assert_equal "no_incomplete_run", snapshot[:wait_reason]
    end

    test "planned run reports work and phase wait reason" do
      cluster = Cluster.create!(composition_version: 1)

      BackfillRunner.plan!(
        cluster_ids: [cluster.id],
        target_checkpoint_height: @checkpoint,
        target_checkpoint_hash: @hash,
        source: "scheduler_experiment"
      )

      snapshot =
        OperationalSnapshot.call(
          current_snapshot:
            {
              development_backfill: {
                phase: "layer1_catchup"
              },
              strict_io: {
                owner: "layer1"
              }
            }
        )

      assert snapshot[:work_available]
      assert_equal "waiting_upstream", snapshot[:pipeline_state]
      assert_equal "phase_layer1_catchup", snapshot[:wait_reason]
      assert_equal 1, snapshot[:remaining_items]
      assert_equal(
        cluster.id,
        snapshot.dig(:current_item, :cluster_id)
      )
    end

    test "planned run with downstream catchup and actor profile backlog reports v5 wait reason" do
      cluster = Cluster.create!(composition_version: 1)

      BackfillRunner.plan!(
        cluster_ids: [cluster.id],
        target_checkpoint_height: @checkpoint,
        target_checkpoint_hash: @hash,
        source: "scheduler_experiment"
      )

      snapshot =
        OperationalSnapshot.call(
          current_snapshot:
            {
              development_backfill: {
                phase: "downstream_catchup"
              },
              layer1: {
                processing: false,
                strict_queue_size: 0,
                strict_worker_busy: false
              },
              cluster: {
                processing: false,
                strict_queue_size: 0,
                strict_worker_busy: false,
                lag: 0
              },
              address_spend_projection: {
                work_available: false,
                caught_up_to_cluster: true,
                processing: false
              },
              actor_profile: {
                pending_work: 5,
                processing: false,
                strict_queue_size: 0,
                strict_worker_busy: false
              },
              strict_io: {
                owner: nil
              }
            }
        )

      assert snapshot[:work_available]
      assert_equal "waiting_actor_profile_v5", snapshot[:pipeline_state]
      assert_equal "actor_profile_v5_priority", snapshot[:wait_reason]
    end
  end
end
