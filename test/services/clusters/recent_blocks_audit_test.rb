# frozen_string_literal: true

require "test_helper"

module Clusters
  class RecentBlocksAuditTest < ActiveSupport::TestCase
    test "audits only multi-address candidates and reports global coverage separately" do
      base_height = 9_900_000 + rand(10_000)
      heights = [base_height, base_height + 1]

      heights.each do |height|
        ClusterProcessedBlock.create!(
          height: height,
          block_hash: format("%064x", height),
          status: "processed",
          processed_at: Time.current
        )
      end

      cluster = Cluster.create!
      candidate_addresses = [
        "candidate-a-#{SecureRandom.hex(8)}",
        "candidate-b-#{SecureRandom.hex(8)}"
      ]

      candidate_addresses.each do |address|
        Address.create!(address: address, cluster: cluster)
      end

      candidate_spent_txid = SecureRandom.hex(32)
      candidate_addresses.each_with_index do |address, index|
        create_cluster_input(
          height: heights.last,
          txid: SecureRandom.hex(32),
          vout: index,
          address: address,
          spent_txid: candidate_spent_txid,
          processed: true
        )
      end

      missing_address = "missing-#{SecureRandom.hex(8)}"
      2.times do |index|
        create_cluster_input(
          height: heights.first,
          txid: SecureRandom.hex(32),
          vout: index,
          address: missing_address,
          spent_txid: SecureRandom.hex(32),
          processed: false
        )
      end

      unclustered_address = "unclustered-#{SecureRandom.hex(8)}"
      Address.create!(address: unclustered_address)

      2.times do |index|
        create_cluster_input(
          height: heights.first,
          txid: SecureRandom.hex(32),
          vout: index,
          address: unclustered_address,
          spent_txid: SecureRandom.hex(32),
          processed: false
        )
      end

      create_cluster_input(
        height: heights.last + 1,
        txid: SecureRandom.hex(32),
        vout: 0,
        address: "not-checkpointed-#{SecureRandom.hex(8)}",
        spent_txid: SecureRandom.hex(32),
        processed: false
      )

      result = Clusters::RecentBlocksAudit.call(limit: 2)

      assert_equal "healthy", result[:status]
      assert_equal heights, result[:heights]

      assert_equal 2, result.dig(:counts, :cluster_inputs)
      assert_equal 1, result.dig(:counts, :candidate_transactions)
      assert_equal 1, result.dig(:counts, :processed_candidate_transactions)
      assert_equal 0, result.dig(:counts, :missing_processed_candidate_transactions)
      assert_equal 6, result.dig(:counts, :total_cluster_inputs)

      assert_equal 0, result.dig(:integrity, :missing_addresses)
      assert_equal 0, result.dig(:integrity, :unclustered_addresses)
      assert_equal 0, result.dig(:integrity, :invalid_cluster_refs)
      assert_equal 0, result.dig(:integrity, :recent_empty_clusters)

      assert_equal 4, result.dig(:coverage, :outside_strict_inputs)
      assert_equal 2, result.dig(:coverage, :missing_address_rows)
      assert_equal 1, result.dig(:coverage, :missing_distinct_addresses)
      assert_equal 2, result.dig(:coverage, :unclustered_rows)
      assert_equal 1, result.dig(:coverage, :unclustered_distinct_addresses)
    end

    private

    def create_cluster_input(height:, txid:, vout:, address:, spent_txid:, processed:)
      ClusterInput.create!(
        block_height: height - 10,
        txid: txid,
        vout: vout,
        address: address,
        amount_btc: BigDecimal("0.1"),
        spent: true,
        spent_txid: spent_txid,
        spent_block_height: height,
        cluster_processed_at: processed ? Time.current : nil
      )
    end
  end
end
