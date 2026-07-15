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

      multi_input_txids =
        txids_with_min_inputs(
          scope.where.not(spent_txid: [nil, ""]),
          min_inputs: minimum_inputs_per_transaction
        )
      expected_inputs = expected_inputs_by_txid(scope, multi_input_txids)
      materializations = expected_inputs.map do |txid, inputs|
        audit_materialization(txid: txid, inputs: inputs)
      end
      multi_address_txids = expected_inputs.keys
      processed = materializations.select { |result| result[:ok] }
      missing_processed_multi_address_txids =
        materializations.reject { |result| result[:ok] }.map { |result| result[:txid] }

      addresses_missing = materializations.sum { |result| result[:addresses_missing] }
      unclustered_addresses = materializations.sum { |result| result[:unclustered_addresses] }
      invalid_cluster_refs = materializations.sum { |result| result[:invalid_cluster_refs] }
      inconsistent_cluster_assignments =
        materializations.count { |result| result[:inconsistent_cluster_assignment] }
      missing_links = materializations.sum { |result| result[:missing_links] }
      unexpected_links = materializations.sum { |result| result[:unexpected_links] }
      empty_clusters = count_empty_clusters

      strict_ok =
        missing_processed_multi_address_txids.empty? &&
        addresses_missing.zero? &&
        unclustered_addresses.zero? &&
        invalid_cluster_refs.zero? &&
        inconsistent_cluster_assignments.zero? &&
        missing_links.zero? &&
        unexpected_links.zero?

      {
        ok: strict_ok,
        height: @height,
        total_cluster_inputs: scope.count,
        distinct_spending_txs: scope.distinct.count(:spent_txid),
        multi_input_txs: multi_input_txids.size,
        multi_address_txs: multi_address_txids.size,
        processed_txs: processed.size,
        processed_inputs: processed.sum { |result| result[:input_count] },
        missing_processed_multi_address_txs: missing_processed_multi_address_txids.size,
        missing_processed_sample: missing_processed_multi_address_txids.first(10),
        addresses_missing: addresses_missing,
        unclustered_addresses: unclustered_addresses,
        invalid_cluster_refs: invalid_cluster_refs,
        inconsistent_cluster_assignments: inconsistent_cluster_assignments,
        missing_links: missing_links,
        unexpected_links: unexpected_links,
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
          invalid_cluster_refs: invalid_cluster_refs,
          inconsistent_cluster_assignments: inconsistent_cluster_assignments,
          missing_links: missing_links,
          unexpected_links: unexpected_links
        ),
        warnings: build_warnings(empty_clusters: empty_clusters)
      }
    end

    private

    def minimum_inputs_per_transaction
      Integer(ENV.fetch("CLUSTER_MIN_INPUTS_PER_TX", "2"))
    end

    def txids_with_min_inputs(scope, min_inputs:)
      scope
        .group(:spent_txid)
        .having("COUNT(*) >= ?", min_inputs)
        .count
        .keys
    end

    def expected_inputs_by_txid(scope, candidate_txids)
      rows =
        scope
          .where(spent_txid: candidate_txids)
          .where.not(address: [nil, ""])
          .where.not(amount_btc: nil)
          .pluck(:spent_txid, :address)

      rows
        .group_by(&:first)
        .transform_values do |tx_rows|
          addresses = tx_rows.map(&:last)
          next [] if addresses.uniq.size < 2

          addresses
        end
        .reject { |_txid, addresses| addresses.empty? }
    end

    def audit_materialization(txid:, inputs:)
      expected_addresses = inputs.uniq.sort
      address_records =
        Address.where(address: expected_addresses).index_by(&:address)
      missing_addresses = expected_addresses - address_records.keys
      records = expected_addresses.filter_map { |address| address_records[address] }
      unclustered = records.count { |record| record.cluster_id.nil? }
      cluster_ids = records.filter_map(&:cluster_id).uniq
      valid_cluster_ids = Cluster.where(id: cluster_ids).pluck(:id)
      invalid_cluster_refs = cluster_ids.size - valid_cluster_ids.size

      expected_pairs = expected_link_pairs(records)
      actual_pairs =
        AddressLink
          .where(
            txid: txid,
            link_type: "multi_input",
            block_height: @height
          )
          .pluck(:address_a_id, :address_b_id)
          .map { |first, second| [first, second].sort }
          .uniq

      missing_links = (expected_pairs - actual_pairs).size
      unexpected_links = (actual_pairs - expected_pairs).size
      inconsistent_cluster_assignment =
        missing_addresses.empty? &&
        unclustered.zero? &&
        invalid_cluster_refs.zero? &&
        cluster_ids.size != 1

      {
        txid: txid,
        input_count: inputs.size,
        addresses_missing: missing_addresses.size,
        unclustered_addresses: unclustered,
        invalid_cluster_refs: invalid_cluster_refs,
        inconsistent_cluster_assignment: inconsistent_cluster_assignment,
        missing_links: missing_links,
        unexpected_links: unexpected_links,
        ok:
          missing_addresses.empty? &&
          unclustered.zero? &&
          invalid_cluster_refs.zero? &&
          !inconsistent_cluster_assignment &&
          missing_links.zero? &&
          unexpected_links.zero?
      }
    end

    def expected_link_pairs(records)
      sorted = records.sort_by(&:id)
      return [] if sorted.size < 2

      pivot = sorted.first
      sorted.drop(1).map do |other|
        [pivot.id, other.id].sort
      end
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
      invalid_cluster_refs:,
      inconsistent_cluster_assignments:,
      missing_links:,
      unexpected_links:
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
      if inconsistent_cluster_assignments.positive?
        issues << {
          check: "inconsistent_cluster_assignments",
          count: inconsistent_cluster_assignments
        }
      end
      issues << { check: "missing_address_links", count: missing_links } if missing_links.positive?
      issues << { check: "unexpected_address_links", count: unexpected_links } if unexpected_links.positive?

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
