# frozen_string_literal: true

module Clusters
  class AuditBlock
    def self.call(height:)
      new(height: height).call
    end

    def initialize(height:)
      @height = height.to_i
    end

    def call
      scope = ClusterInput.where(spent_block_height: @height)

      multi_input_txids = txids_with_min_inputs(scope, min_inputs: 2)
      multi_address_txids = txids_with_min_distinct_addresses(scope, min_addresses: 2)
      processed_txids = processed_txids(scope)

      missing_processed_multi_address_txids =
        multi_address_txids - processed_txids

      addresses_missing = count_addresses_missing(scope, multi_address_txids)
      unclustered_addresses = count_unclustered_addresses(scope, multi_address_txids)
      invalid_cluster_refs = count_invalid_cluster_refs(scope, multi_address_txids)
      empty_clusters = count_empty_clusters

      strict_ok =
        missing_processed_multi_address_txids.empty? &&
        addresses_missing.zero? &&
        unclustered_addresses.zero? &&
        invalid_cluster_refs.zero?

      {
        ok: strict_ok,
        height: @height,
        total_cluster_inputs: scope.count,
        distinct_spending_txs: scope.distinct.count(:spent_txid),
        multi_input_txs: multi_input_txids.size,
        multi_address_txs: multi_address_txids.size,
        processed_txs: processed_txids.size,
        processed_inputs: scope.where.not(cluster_processed_at: nil).count,
        missing_processed_multi_address_txs: missing_processed_multi_address_txids.size,
        missing_processed_sample: missing_processed_multi_address_txids.first(10),
        addresses_missing: addresses_missing,
        unclustered_addresses: unclustered_addresses,
        invalid_cluster_refs: invalid_cluster_refs,
        empty_clusters: empty_clusters,
        empty_clusters_blocking: false,
        maintenance_warning: empty_clusters.positive?,
        clusters_total: Cluster.count,
        addresses_total: Address.count,
        address_links_total: AddressLink.count,
        issues: build_issues(
          missing_processed_multi_address_txids: missing_processed_multi_address_txids,
          addresses_missing: addresses_missing,
          unclustered_addresses: unclustered_addresses,
          invalid_cluster_refs: invalid_cluster_refs
        ),
        warnings: build_warnings(empty_clusters: empty_clusters)
      }
    end

    private

    def txids_with_min_inputs(scope, min_inputs:)
      scope
        .group(:spent_txid)
        .having("COUNT(*) >= ?", min_inputs)
        .count
        .keys
    end

    def txids_with_min_distinct_addresses(scope, min_addresses:)
      scope
        .where.not(address: [nil, ""])
        .group(:spent_txid)
        .having("COUNT(DISTINCT address) >= ?", min_addresses)
        .count
        .keys
    end

    def processed_txids(scope)
      scope
        .where.not(cluster_processed_at: nil)
        .distinct
        .pluck(:spent_txid)
    end

    def count_addresses_missing(scope, txids)
      return 0 if txids.empty?

      scope
        .where(spent_txid: txids)
        .where.not(address: [nil, ""])
        .joins("LEFT JOIN addresses ON addresses.address = cluster_inputs.address")
        .where(addresses: { id: nil })
        .count
    end

    def count_unclustered_addresses(scope, txids)
      return 0 if txids.empty?

      scope
        .where(spent_txid: txids)
        .where.not(address: [nil, ""])
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .where(addresses: { cluster_id: nil })
        .count
    end

    def count_invalid_cluster_refs(scope, txids)
      return 0 if txids.empty?

      scope
        .where(spent_txid: txids)
        .where.not(address: [nil, ""])
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .joins("LEFT JOIN clusters ON clusters.id = addresses.cluster_id")
        .where.not(addresses: { cluster_id: nil })
        .where(clusters: { id: nil })
        .count
    end

    def count_empty_clusters
      Cluster
        .left_joins(:addresses)
        .where(addresses: { id: nil })
        .count
    end

    def build_issues(
      missing_processed_multi_address_txids:,
      addresses_missing:,
      unclustered_addresses:,
      invalid_cluster_refs:
    )
      issues = []

      if missing_processed_multi_address_txids.any?
        issues << {
          check: "multi_address_txs_processed",
          count: missing_processed_multi_address_txids.size,
          sample: missing_processed_multi_address_txids.first(10)
        }
      end

      issues << { check: "addresses_missing", count: addresses_missing } if addresses_missing.positive?
      issues << { check: "unclustered_addresses", count: unclustered_addresses } if unclustered_addresses.positive?
      issues << { check: "invalid_cluster_refs", count: invalid_cluster_refs } if invalid_cluster_refs.positive?

      issues
    end

    def build_warnings(empty_clusters:)
      return [] unless empty_clusters.positive?

      [
        {
          check: "empty_clusters",
          count: empty_clusters,
          blocking: false
        }
      ]
    end
  end
end
