# frozen_string_literal: true

require "test_helper"

module Clusters
  class AuditBlockTest < ActiveSupport::TestCase
    setup do
      AddressLink.delete_all
      ClusterInput.delete_all
      Address.delete_all
      Cluster.delete_all
    end

    test "reports historical empty clusters as non blocking warnings" do
      height = 910_001
      cluster = create_cluster!
      create_cluster!

      create_address!("audit-empty-a", cluster: cluster)
      create_address!("audit-empty-b", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-empty-tx",
        addresses: %w[audit-empty-a audit-empty-b],
        processed: true
      )

      result = Clusters::AuditBlock.call(height: height)

      assert result[:ok]
      assert_operator result[:empty_clusters], :>=, 1
      assert_equal false, result[:empty_clusters_blocking]
      assert_equal true, result[:maintenance_warning]
      assert result[:warnings].any? { |warning|
        warning[:check] == "empty_clusters" &&
          warning[:blocking] == false
      }
      refute_includes result[:issues].map { |issue| issue[:check] }, "empty_clusters"
    end

    test "returns no maintenance warning when no empty cluster exists" do
      height = 910_002
      cluster = create_cluster!

      create_address!("audit-clean-a", cluster: cluster)
      create_address!("audit-clean-b", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-clean-tx",
        addresses: %w[audit-clean-a audit-clean-b],
        processed: true
      )

      result = Clusters::AuditBlock.call(height: height)

      assert result[:ok]
      assert_equal 0, result[:empty_clusters]
      assert_equal false, result[:maintenance_warning]
      assert_equal [], result[:warnings]
    end

    test "blocks unprocessed multi address transactions" do
      height = 910_003
      cluster = create_cluster!

      create_address!("audit-unprocessed-a", cluster: cluster)
      create_address!("audit-unprocessed-b", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-unprocessed-tx",
        addresses: %w[audit-unprocessed-a audit-unprocessed-b],
        processed: false
      )

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_operator result[:missing_processed_multi_address_txs], :>, 0
      assert_issue result, "multi_address_txs_processed"
    end

    test "blocks missing addresses" do
      height = 910_004
      cluster = create_cluster!

      create_address!("audit-missing-a", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-missing-tx",
        addresses: %w[audit-missing-a audit-missing-b],
        processed: true
      )

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_operator result[:addresses_missing], :>, 0
      assert_issue result, "addresses_missing"
    end

    test "blocks addresses present without cluster" do
      height = 910_005
      cluster = create_cluster!

      create_address!("audit-unclustered-a", cluster: cluster)
      create_address!("audit-unclustered-b", cluster: nil)
      create_cluster_inputs!(
        height: height,
        txid: "audit-unclustered-tx",
        addresses: %w[audit-unclustered-a audit-unclustered-b],
        processed: true
      )

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_operator result[:unclustered_addresses], :>, 0
      assert_issue result, "unclustered_addresses"
    end

    test "blocks invalid cluster references" do
      height = 910_006
      cluster = create_cluster!
      invalid_cluster_id = cluster.id + 100_000

      create_address!("audit-invalid-a", cluster: cluster)

      ActiveRecord::Base.connection.disable_referential_integrity do
        Address.create!(
          address: "audit-invalid-b",
          cluster_id: invalid_cluster_id
        )
      end

      create_cluster_inputs!(
        height: height,
        txid: "audit-invalid-tx",
        addresses: %w[audit-invalid-a audit-invalid-b],
        processed: true
      )

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_operator result[:invalid_cluster_refs], :>, 0
      assert_issue result, "invalid_cluster_refs"
    end

    test "preserves existing keys and adds warning keys" do
      result = Clusters::AuditBlock.call(height: 910_007)

      %i[
        processed_txs
        processed_inputs
        address_links_total
        empty_clusters
        issues
      ].each do |key|
        assert_includes result, key
      end

      %i[
        empty_clusters_blocking
        maintenance_warning
        warnings
      ].each do |key|
        assert_includes result, key
      end
    end

    private

    def create_cluster!
      Cluster.create!
    end

    def create_address!(address, cluster:)
      Address.create!(
        address: address,
        cluster: cluster
      )
    end

    def create_cluster_inputs!(height:, txid:, addresses:, processed:)
      addresses.each_with_index do |address, index|
        ClusterInput.create!(
          block_height: height - 1,
          txid: "source-#{txid}-#{index}",
          vout: index,
          address: address,
          amount_btc: "1.00000000",
          spent: true,
          spent_txid: txid,
          spent_block_height: height,
          cluster_processed_at: processed ? Time.current : nil
        )
      end
    end

    def assert_issue(result, check)
      assert_includes result[:issues].map { |issue| issue[:check] }, check
    end
  end
end
