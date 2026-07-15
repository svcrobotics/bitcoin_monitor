# frozen_string_literal: true

require "test_helper"

module AddressSpendStats
  class NextRecordTest <
    ActiveSupport::TestCase

    test "returns the oldest unprojected Cluster block" do
      first =
        create_source_block(
          height: 1_600_001
        )

      second =
        create_source_block(
          height: 1_600_002
        )

      selected =
        NextRecord.call

      assert_equal first.id,
                   selected.id

      assert_not_equal second.id,
                       selected.id
    end

    test "skips a completed checkpoint with matching hash" do
      first =
        create_source_block(
          height: 1_600_011
        )

      second =
        create_source_block(
          height: 1_600_012
        )

      AddressSpendProjectionBlock.create!(
        height: first.height,
        block_hash: first.block_hash,
        status: "completed",
        completed_at: Time.current
      )

      selected =
        NextRecord.call

      assert_equal second.id,
                   selected.id
    end

    test "returns a completed checkpoint when the hash changed" do
      source =
        create_source_block(
          height: 1_600_021,
          block_hash: "new-cluster-hash"
        )

      AddressSpendProjectionBlock.create!(
        height: source.height,
        block_hash: "old-projection-hash",
        status: "completed",
        completed_at: Time.current
      )

      selected =
        NextRecord.call

      assert_equal source.id,
                   selected.id
    end

    test "skips a failed checkpoint at maximum attempts" do
      first =
        create_source_block(
          height: 1_600_031
        )

      second =
        create_source_block(
          height: 1_600_032
        )

      AddressSpendProjectionBlock.create!(
        height: first.height,
        block_hash: first.block_hash,
        status: "failed",
        attempts:
          AddressSpendStats::Config.max_attempts,
        error_message: "permanent failure"
      )

      selected =
        NextRecord.call

      assert_equal second.id,
                   selected.id
    end

    test "retries only stale processing checkpoints" do
      stale =
        create_source_block(
          height: 1_600_041
        )

      fresh =
        create_source_block(
          height: 1_600_042
        )

      fallback =
        create_source_block(
          height: 1_600_043
        )

      AddressSpendProjectionBlock.create!(
        height: stale.height,
        block_hash: stale.block_hash,
        status: "processing",
        attempts: 1,
        processing_started_at:
          (
            AddressSpendStats::Config
              .processing_stale_after_seconds +
            60
          ).seconds.ago
      )

      AddressSpendProjectionBlock.create!(
        height: fresh.height,
        block_hash: fresh.block_hash,
        status: "processing",
        attempts: 1,
        processing_started_at:
          Time.current
      )

      selected =
        NextRecord.call

      assert_equal stale.id,
                   selected.id

      AddressSpendProjectionBlock
        .find_by!(
          height: stale.height
        )
        .update!(
          status: "completed",
          completed_at: Time.current
        )

      selected_after_stale =
        NextRecord.call

      assert_equal fallback.id,
                   selected_after_stale.id
    end

    private

    def create_source_block(
      height:,
      block_hash: nil
    )
      ClusterProcessedBlock.create!(
        height: height,
        block_hash:
          block_hash ||
          "cluster-hash-#{height}",
        status: "processed",
        scan_result: {},
        cleanup_result: {},
        audit_result: {},
        stage_timings: {},
        processed_at: Time.current
      )
    end
  end
end
