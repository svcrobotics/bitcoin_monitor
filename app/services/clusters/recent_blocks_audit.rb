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
      scope = ClusterInput.where(spent_block_height: heights)

      total_inputs = scope.count
      distinct_addresses = scope.distinct.count(:address)

      missing_addresses =
        scope
          .joins("LEFT JOIN addresses ON addresses.address = cluster_inputs.address")
          .where(addresses: { id: nil })
          .count

      unclustered_addresses =
        scope
          .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
          .where(addresses: { cluster_id: nil })
          .count

      invalid_cluster_refs =
        scope
          .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
          .joins("LEFT JOIN clusters ON clusters.id = addresses.cluster_id")
          .where.not(addresses: { cluster_id: nil })
          .where(clusters: { id: nil })
          .count

      touched_clusters =
        scope
          .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
          .distinct
          .count("addresses.cluster_id")

      recent_empty_clusters =
        Cluster
          .left_joins(:addresses)
          .where(addresses: { id: nil })
          .where("clusters.created_at >= ?", 1.hour.ago)
          .count

      status =
        if total_inputs.positive? &&
           missing_addresses.zero? &&
           unclustered_addresses.zero? &&
           invalid_cluster_refs.zero? &&
           recent_empty_clusters.zero?
          "healthy"
        else
          "warning"
        end

      {
        module: "clusters_recent_blocks_audit",
        source: "clusters_recent_blocks_audit",
        generated_at: Time.current,
        status: status,
        block_limit: @limit,
        heights: heights,
        counts: {
          cluster_inputs: total_inputs,
          distinct_input_addresses: distinct_addresses,
          touched_clusters: touched_clusters
        },
        integrity: {
          missing_addresses: missing_addresses,
          unclustered_addresses: unclustered_addresses,
          invalid_cluster_refs: invalid_cluster_refs,
          recent_empty_clusters: recent_empty_clusters
        },
        activity: {
          last_cluster_input_at: scope.maximum(:created_at),
          last_cluster_processed_at: scope.maximum(:cluster_processed_at)
        }
      }
    end

    private

    def recent_processed_heights
      max_height = ClusterInput.maximum(:spent_block_height)
      return [] unless max_height

      (max_height - @limit + 1..max_height).to_a
    end
  end
end
