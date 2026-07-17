# frozen_string_literal: true

module Clusters
  class CleanupEmptyClusters
    def self.call
      new.call
    end

    def call
      deleted = 0

      ActiveRecord::Base.transaction do
        empty_ids =
          Cluster
            .left_joins(:addresses)
            .where(addresses: { id: nil })
            .pluck(:id)

        deleted = empty_ids.size

        Cluster.where(id: empty_ids).delete_all if deleted.positive?
      end

      {
        ok: true,
        deleted_empty_clusters: deleted,
        clusters_total: Cluster.count,
        addresses_total: Address.count,
        empty_clusters_count: empty_clusters_count
      }
    end

    private

    def empty_clusters_count
      Cluster
        .left_joins(:addresses)
        .where(addresses: { id: nil })
        .count
    end
  end
end
