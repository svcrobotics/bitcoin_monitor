# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

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

    test "blocks multi address transactions without provenance links" do
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

    test "ignores a misleading historical processed marker" do
      height = 910_008
      cluster = create_cluster!

      create_address!("audit-marker-a", cluster: cluster)
      create_address!("audit-marker-b", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-marker-tx",
        addresses: %w[audit-marker-a audit-marker-b],
        processed: false,
        marker: Time.current
      )

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_equal 1, result[:missing_links]
      assert_issue result, "missing_address_links"
    end

    test "accepts exact provenance when historical marker is nil" do
      height = 910_009
      cluster = create_cluster!

      create_address!("audit-provenance-a", cluster: cluster)
      create_address!("audit-provenance-b", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-provenance-tx",
        addresses: %w[audit-provenance-a audit-provenance-b],
        processed: true,
        marker: nil
      )

      result = Clusters::AuditBlock.call(height: height)

      assert result[:ok]
      assert_equal 1, result[:processed_txs]
      assert_equal 2, result[:processed_inputs]
      assert_equal 0, result[:missing_links]
    end

    test "blocks addresses assigned to inconsistent clusters" do
      height = 910_010
      first_cluster = create_cluster!
      second_cluster = create_cluster!

      create_address!("audit-split-a", cluster: first_cluster)
      create_address!("audit-split-b", cluster: second_cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-split-tx",
        addresses: %w[audit-split-a audit-split-b],
        processed: true
      )

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_equal 1, result[:inconsistent_cluster_assignments]
      assert_issue result, "inconsistent_cluster_assignments"
    end

    test "blocks an incomplete star of provenance links" do
      height = 910_011
      cluster = create_cluster!
      addresses = %w[audit-star-a audit-star-b audit-star-c]

      addresses.each { |address| create_address!(address, cluster: cluster) }
      create_cluster_inputs!(
        height: height,
        txid: "audit-star-tx",
        addresses: addresses,
        processed: true
      )
      AddressLink.order(:id).last.delete

      result = Clusters::AuditBlock.call(height: height)

      refute result[:ok]
      assert_equal 1, result[:missing_links]
      assert_issue result, "missing_address_links"
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
      create_address!("audit-invalid-a", cluster: cluster)
      create_address!("audit-invalid-b", cluster: cluster)

      create_cluster_inputs!(
        height: height,
        txid: "audit-invalid-tx",
        addresses: %w[audit-invalid-a audit-invalid-b],
        processed: true
      )

      original_where = Cluster.method(:where)
      missing_cluster_relation = Object.new
      missing_cluster_relation.define_singleton_method(:pluck) { |_column| [] }

      result =
        Cluster.stub(
          :where,
          lambda do |conditions|
            if conditions == { id: [cluster.id] }
              missing_cluster_relation
            else
              original_where.call(conditions)
            end
          end
        ) do
          Clusters::AuditBlock.call(height: height)
        end

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

    test "audit performs only bounded reads of strict and Cluster tables" do
      height = 910_012
      cluster = create_cluster!

      create_address!("audit-read-only-a", cluster: cluster)
      create_address!("audit-read-only-b", cluster: cluster)
      create_cluster_inputs!(
        height: height,
        txid: "audit-read-only-tx",
        addresses: %w[audit-read-only-a audit-read-only-b],
        processed: true
      )

      statements = capture_sql do
        result = Clusters::AuditBlock.call(height: height)
        assert result[:ok]
      end

      writes = statements.grep(/\A\s*(?:UPDATE|INSERT|DELETE)\b/i)
      forbidden_reads = statements.grep(/\b(?:tx_outputs|utxo_outputs)\b/i)

      assert_empty writes
      assert_empty forbidden_reads
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

    def create_cluster_inputs!(height:, txid:, addresses:, processed:, marker: nil)
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
          cluster_processed_at: marker
        )
      end

      return unless processed

      records = Address.where(address: addresses).order(:id).to_a
      return if records.size < 2

      pivot = records.first
      records.drop(1).each do |other|
        first_id, second_id = [pivot.id, other.id].sort
        AddressLink.create!(
          address_a_id: first_id,
          address_b_id: second_id,
          link_type: "multi_input",
          txid: txid,
          block_height: height
        )
      end
    end

    def assert_issue(result, check)
      assert_includes result[:issues].map { |issue| issue[:check] }, check
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        statements << sql unless payload[:name] == "SCHEMA"
      end

      ActiveSupport::Notifications.subscribed(
        subscriber,
        "sql.active_record"
      ) { yield }
      statements
    end
  end
end
