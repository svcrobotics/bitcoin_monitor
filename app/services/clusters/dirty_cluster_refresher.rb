# frozen_string_literal: true

module Clusters
  class DirtyClusterRefresher
    def self.call(cluster_ids:)
      new(cluster_ids: cluster_ids).call
    end

    def initialize(cluster_ids:)
      @cluster_ids = Array(cluster_ids).compact.uniq
    end

    def call
      return 0 if cluster_ids.empty?

      puts "[cluster_scan] refresh_dirty_clusters count=#{cluster_ids.size}"

      refreshed = 0

      Cluster.where(id: cluster_ids).find_each(batch_size: 100) do |cluster|
        cluster.recalculate_stats!
        ClusterAggregator.call(cluster)
        refreshed += 1
      rescue StandardError => e
        puts "[cluster_scan] refresh_dirty_cluster_failed cluster_id=#{cluster.id} error=#{e.class}: #{e.message}"
      end

      refreshed
    end

    private

    attr_reader :cluster_ids
  end
end
