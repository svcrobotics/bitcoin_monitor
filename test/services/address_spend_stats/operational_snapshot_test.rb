# frozen_string_literal: true

require "test_helper"

module AddressSpendStats
  class OperationalSnapshotTest <
    ActiveSupport::TestCase

    test "reports healthy when projection reaches Cluster tip" do
      first =
        create_source_block(
          height: 1_800_001
        )

      second =
        create_source_block(
          height: 1_800_002
        )

      create_completed_checkpoint(first)
      create_completed_checkpoint(second)

      snapshot =
        service.call

      assert_equal(
        "healthy",
        snapshot[:status]
      )

      assert_equal(
        second.height,
        snapshot.dig(
          :sync,
          :cluster_tip
        )
      )

      assert_equal(
        second.height,
        snapshot.dig(
          :sync,
          :projection_tip
        )
      )

      assert_equal(
        0,
        snapshot.dig(
          :sync,
          :lag
        )
      )

      assert_equal(
        true,
        snapshot.dig(
          :sync,
          :caught_up_to_cluster
        )
      )

      assert_nil(
        snapshot.dig(
          :sync,
          :next_record_height
        )
      )
    end

    test "reports waiting while a certified block remains" do
      first =
        create_source_block(
          height: 1_800_011
        )

      second =
        create_source_block(
          height: 1_800_012
        )

      create_completed_checkpoint(first)

      snapshot =
        service.call

      assert_equal(
        "waiting",
        snapshot[:status]
      )

      assert_equal(
        1,
        snapshot.dig(
          :sync,
          :lag
        )
      )

      assert_equal(
        second.height,
        snapshot.dig(
          :sync,
          :next_record_height
        )
      )

      assert_equal(
        false,
        snapshot.dig(
          :sync,
          :caught_up_to_cluster
        )
      )

      assert_empty(
        snapshot[:issues]
      )
    end

    test "reports warning for a failed checkpoint" do
      source =
        create_source_block(
          height: 1_800_021
        )

      AddressSpendProjectionBlock.create!(
        height:
          source.height,
        block_hash:
          source.block_hash,
        status:
          "failed",
        attempts:
          1,
        error_message:
          "projection failure"
      )

      snapshot =
        service.call

      assert_equal(
        "warning",
        snapshot[:status]
      )

      assert_includes(
        snapshot[:issues],
        "failed_checkpoint"
      )

      assert_equal(
        source.height,
        snapshot.dig(
          :failed_checkpoint,
          :height
        )
      )

      assert_equal(
        "projection failure",
        snapshot.dig(
          :failed_checkpoint,
          :error_message
        )
      )
    end

    test "reports migration pending without querying projection tables" do
      snapshot =
        OperationalSnapshot
          .new(
            runtime:
              runtime_snapshot,

            table_checker:
              -> { false }
          )
          .call

      assert_equal(
        "unavailable",
        snapshot[:status]
      )

      assert_equal(
        false,
        snapshot[:available]
      )

      assert_equal(
        true,
        snapshot[:migration_pending]
      )

      assert_includes(
        snapshot[:issues],
        "migration_pending"
      )
    end

    test "dead jobs produce one serializable bounded issue" do
      snapshot = OperationalSnapshot.new(
        runtime: runtime_snapshot.merge(dead_jobs: 2)
      ).call

      assert_equal ["dead_jobs_present"], snapshot[:issues]
      assert JSON.generate(snapshot)
    end

    private

    def service
      OperationalSnapshot.new(
        runtime:
          runtime_snapshot
      )
    end

    def runtime_snapshot
      {
        configured: false,
        process_present: false,
        process_count: 0,
        busy_workers: 0,
        queue_size: 0,
        scheduled_jobs: 0,
        retry_jobs: 0,
        dead_jobs: 0
      }
    end

    def create_source_block(
      height:
    )
      ClusterProcessedBlock.create!(
        height: height,
        block_hash:
          "snapshot-block-hash-"           "#{height}",
        status: "processed",
        scan_result: {},
        cleanup_result: {},
        audit_result: {},
        stage_timings: {},
        processed_at:
          Time.current
      )
    end

    def create_completed_checkpoint(
      source
    )
      AddressSpendProjectionBlock.create!(
        height:
          source.height,
        block_hash:
          source.block_hash,
        status:
          "completed",
        input_count:
          1,
        address_count:
          1,
        total_sent_sats:
          10_000,
        attempts:
          1,
        completed_at:
          Time.current
      )
    end
  end
end
