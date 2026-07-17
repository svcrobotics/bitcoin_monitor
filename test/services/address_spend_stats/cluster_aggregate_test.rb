# frozen_string_literal: true

require "test_helper"

module AddressSpendStats
  class ClusterAggregateTest <
    ActiveSupport::TestCase

    test "aggregates additive spend facts for current cluster membership" do
      height = 1_900_001

      mark_projection_completed(
        height: height
      )

      cluster =
        create_cluster(
          address_count: 2
        )

      first =
        create_address(
          cluster,
          "aggregate-first"
        )

      second =
        create_address(
          cluster,
          "aggregate-second"
        )

      other_cluster =
        create_cluster(
          address_count: 1
        )

      other =
        create_address(
          other_cluster,
          "aggregate-other"
        )

      create_stat(
        address: first,
        total_sent_sats:
          10_000_000,
        spent_inputs_count: 2,
        first_spent_height:
          height - 20,
        last_spent_height:
          height - 5,
        source_height:
          height
      )

      create_stat(
        address: second,
        total_sent_sats:
          25_000_000,
        spent_inputs_count: 3,
        first_spent_height:
          height - 30,
        last_spent_height:
          height - 2,
        source_height:
          height
      )

      create_stat(
        address: other,
        total_sent_sats:
          99_000_000,
        spent_inputs_count: 99,
        first_spent_height:
          height - 100,
        last_spent_height:
          height,
        source_height:
          height
      )

      result =
        ClusterAggregate.call(
          cluster_id:
            cluster.id,
          required_height:
            height
        )

      assert_equal(
        35_000_000,
        result[:total_sent_sats]
      )

      assert_equal(
        BigDecimal("0.35"),
        result[:total_sent_btc]
      )

      assert_equal(
        5,
        result[:spent_inputs_count]
      )

      assert_equal(
        height - 30,
        result[:first_spent_height]
      )

      assert_equal(
        height - 2,
        result[:last_spent_height]
      )

      assert_equal(
        2,
        result[
          :addresses_with_spend_count
        ]
      )

      assert_equal(
        height,
        result[:projection_tip]
      )
    end

    test "returns zero additive facts for a cluster without spends" do
      height = 1_900_011

      mark_projection_completed(
        height: height
      )

      cluster =
        create_cluster(
          address_count: 1
        )

      create_address(
        cluster,
        "aggregate-empty"
      )

      result =
        ClusterAggregate.call(
          cluster_id:
            cluster.id,
          required_height:
            height
        )

      assert_equal(
        0,
        result[:total_sent_sats]
      )

      assert_equal(
        BigDecimal("0"),
        result[:total_sent_btc]
      )

      assert_equal(
        0,
        result[:spent_inputs_count]
      )

      assert_nil(
        result[:first_spent_height]
      )

      assert_nil(
        result[:last_spent_height]
      )

      assert_equal(
        0,
        result[
          :addresses_with_spend_count
        ]
      )
    end

    test "rejects a projection behind the required height" do
      completed_height =
        1_900_021

      required_height =
        completed_height + 1

      mark_projection_completed(
        height:
          completed_height
      )

      create_source_block(
        height:
          required_height
      )

      cluster =
        create_cluster(
          address_count: 1
        )

      error =
        assert_raises(
          ClusterAggregate::
            ProjectionNotReady
        ) do
          ClusterAggregate.call(
            cluster_id:
              cluster.id,
            required_height:
              required_height
          )
        end

      assert_equal(
        completed_height,
        error.projection_tip
      )

      assert_equal(
        required_height,
        error.next_record_height
      )
    end

    test "rejects an earlier checkpoint requiring replay" do
      replay_height =
        1_900_031

      required_height =
        replay_height + 1

      replay_source =
        create_source_block(
          height:
            replay_height,
          block_hash:
            "new-replay-hash"
        )

      AddressSpendProjectionBlock.create!(
        height:
          replay_height,
        block_hash:
          "old-replay-hash",
        status:
          "completed",
        completed_at:
          Time.current
      )

      final_source =
        create_source_block(
          height:
            required_height
        )

      AddressSpendProjectionBlock.create!(
        height:
          final_source.height,
        block_hash:
          final_source.block_hash,
        status:
          "completed",
        completed_at:
          Time.current
      )

      cluster =
        create_cluster(
          address_count: 1
        )

      error =
        assert_raises(
          ClusterAggregate::
            ProjectionNotReady
        ) do
          ClusterAggregate.call(
            cluster_id:
              cluster.id,
            required_height:
              required_height
          )
        end

      assert_equal(
        required_height,
        error.projection_tip
      )

      assert_equal(
        replay_source.height,
        error.next_record_height
      )
    end

    private

    def create_cluster(
      address_count:
    )
      Cluster.create!(
        address_count:
          address_count,
        first_seen_height:
          1_899_000,
        last_seen_height:
          1_900_000,
        composition_version:
          1
      )
    end

    def create_address(
      cluster,
      prefix
    )
      Address.create!(
        address:
          "#{prefix}-"           "#{SecureRandom.hex(8)}",
        cluster:
          cluster
      )
    end

    def create_stat(
      address:,
      total_sent_sats:,
      spent_inputs_count:,
      first_spent_height:,
      last_spent_height:,
      source_height:
    )
      AddressSpendStat.create!(
        address:
          address.address,
        total_sent_sats:
          total_sent_sats,
        spent_inputs_count:
          spent_inputs_count,
        first_spent_height:
          first_spent_height,
        last_spent_height:
          last_spent_height,
        source_height:
          source_height,
        projection_version:
          AddressSpendStats::
            ProjectBlock::
            PROJECTION_VERSION
      )
    end

    def mark_projection_completed(
      height:
    )
      source =
        create_source_block(
          height: height
        )

      AddressSpendProjectionBlock.create!(
        height:
          source.height,
        block_hash:
          source.block_hash,
        status:
          "completed",
        completed_at:
          Time.current
      )
    end

    def create_source_block(
      height:,
      block_hash: nil
    )
      ClusterProcessedBlock.create!(
        height:
          height,
        block_hash:
          block_hash ||
          "aggregate-hash-#{height}",
        status:
          "processed",
        scan_result: {},
        cleanup_result: {},
        audit_result: {},
        stage_timings: {},
        processed_at:
          Time.current
      )
    end
  end
end
