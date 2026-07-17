# frozen_string_literal: true

module Clusters
  class RecentBlocksAudit
    DEFAULT_LIMIT = 10

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit
    end

    def call
      heights = recent_processed_heights
      global_scope = ClusterInput.where(spent_block_height: heights)
      candidate_txids = multi_address_txids(global_scope)
      strict_scope = global_scope.where(spent_txid: candidate_txids)

      candidate_transactions = candidate_txids.size
      processed_candidate_transactions =
        if candidate_txids.empty?
          0
        else
          strict_scope
            .where.not(cluster_processed_at: nil)
            .distinct
            .count(:spent_txid)
        end

      missing_processed_candidate_transactions =
        [candidate_transactions - processed_candidate_transactions, 0].max

      strict_missing = missing_addresses(strict_scope)
      strict_unclustered = unclustered_addresses(strict_scope)
      strict_invalid_refs = invalid_cluster_refs(strict_scope)
      recent_empty_clusters = recent_empty_clusters_count

      strict_status =
        if heights.any? &&
           missing_processed_candidate_transactions.zero? &&
           strict_missing[:rows].zero? &&
           strict_unclustered[:rows].zero? &&
           strict_invalid_refs.zero? &&
           recent_empty_clusters.zero?
          "healthy"
        else
          "warning"
        end

      global_missing = missing_addresses(global_scope)
      global_unclustered = unclustered_addresses(global_scope)
      global_invalid_refs = invalid_cluster_refs(global_scope)

      touched_clusters =
        strict_scope
          .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
          .where.not(addresses: { cluster_id: nil })
          .distinct
          .count("addresses.cluster_id")

      {
        module: "clusters_recent_blocks_audit",
        source: "clusters_recent_blocks_audit",
        generated_at: Time.current,
        status: strict_status,
        block_limit: @limit,
        heights: heights,
        counts: {
          cluster_inputs: strict_scope.count,
          distinct_input_addresses: distinct_nonblank_addresses(strict_scope),
          candidate_transactions: candidate_transactions,
          processed_candidate_transactions: processed_candidate_transactions,
          missing_processed_candidate_transactions: missing_processed_candidate_transactions,
          touched_clusters: touched_clusters,
          total_cluster_inputs: global_scope.count,
          total_transactions: global_scope.distinct.count(:spent_txid),
          total_distinct_addresses: distinct_nonblank_addresses(global_scope)
        },
        integrity: {
          missing_addresses: strict_missing[:rows],
          unclustered_addresses: strict_unclustered[:rows],
          invalid_cluster_refs: strict_invalid_refs,
          recent_empty_clusters: recent_empty_clusters
        },
        coverage: {
          total_inputs: global_scope.count,
          total_transactions: global_scope.distinct.count(:spent_txid),
          distinct_addresses: distinct_nonblank_addresses(global_scope),
          strict_inputs: strict_scope.count,
          strict_transactions: candidate_transactions,
          strict_distinct_addresses: distinct_nonblank_addresses(strict_scope),
          outside_strict_inputs: [global_scope.count - strict_scope.count, 0].max,
          missing_address_rows: global_missing[:rows],
          missing_distinct_addresses: global_missing[:distinct_addresses],
          unclustered_rows: global_unclustered[:rows],
          unclustered_distinct_addresses: global_unclustered[:distinct_addresses],
          invalid_cluster_refs: global_invalid_refs
        },
        activity: {
          last_cluster_input_at: global_scope.maximum(:created_at),
          last_cluster_processed_at: strict_scope.maximum(:cluster_processed_at)
        }
      }
    end

    private

    def recent_processed_heights
      ClusterProcessedBlock
        .where(status: "processed")
        .order(height: :desc)
        .limit(@limit)
        .pluck(:height)
        .sort
    end

    def multi_address_txids(scope)
      scope
        .where.not(address: [nil, ""])
        .group(:spent_txid)
        .having("COUNT(DISTINCT address) >= 2")
        .pluck(:spent_txid)
    end

    def distinct_nonblank_addresses(scope)
      scope
        .where.not(address: [nil, ""])
        .distinct
        .count(:address)
    end

    def missing_addresses(scope)
      relation =
        scope
          .where.not(address: [nil, ""])
          .joins("LEFT JOIN addresses ON addresses.address = cluster_inputs.address")
          .where(addresses: { id: nil })

      {
        rows: relation.count,
        distinct_addresses: relation.distinct.count(:address)
      }
    end

    def unclustered_addresses(scope)
      relation =
        scope
          .where.not(address: [nil, ""])
          .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
          .where(addresses: { cluster_id: nil })

      {
        rows: relation.count,
        distinct_addresses: relation.distinct.count(:address)
      }
    end

    def invalid_cluster_refs(scope)
      scope
        .where.not(address: [nil, ""])
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .joins("LEFT JOIN clusters ON clusters.id = addresses.cluster_id")
        .where.not(addresses: { cluster_id: nil })
        .where(clusters: { id: nil })
        .count
    end

    def recent_empty_clusters_count
      Cluster
        .left_joins(:addresses)
        .where(addresses: { id: nil })
        .where("clusters.created_at >= ?", 1.hour.ago)
        .count
    end
  end
end
