# frozen_string_literal: true

require "test_helper"

module Clusters
  class StrictHealthSnapshotTest < ActiveSupport::TestCase
    test "uses ClusterProcessedBlock as the official strict checkpoint" do
      base_height = 9_800_000 + rand(10_000)

      ClusterProcessedBlock.create!(
        height: base_height,
        block_hash: format("%064x", base_height),
        status: "processed",
        processed_at: Time.current
      )

      ClusterInput.create!(
        block_height: base_height,
        txid: SecureRandom.hex(32),
        vout: 0,
        address: "ahead-#{SecureRandom.hex(8)}",
        amount_btc: BigDecimal("0.1"),
        spent: true,
        spent_txid: SecureRandom.hex(32),
        spent_block_height: base_height + 1,
        cluster_processed_at: Time.current
      )

      service = Clusters::StrictHealthSnapshot.new

      assert_equal base_height, service.send(:strict_cluster_tip)
      assert_equal [base_height], service.send(:strict_recent_heights).last(1)
    end
  end
end
